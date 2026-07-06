#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

if ! command -v npm >/dev/null 2>&1; then
  echo "需要先安装 Node.js/npm。"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "需要先安装 curl。"
  exit 1
fi

if [[ ! -f "package.json" ]]; then
  echo "请在 worker 目录运行此脚本。"
  exit 1
fi

read -r -p "请输入 Cloudflare Worker 名称 [telegram-chatbot]: " WORKER_NAME
WORKER_NAME="${WORKER_NAME:-telegram-chatbot}"

read -r -s -p "请输入 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
echo
read -r -p "请输入管理员 Telegram 数字 ID: " TELEGRAM_ADMIN_ID
read -r -p "管理员显示名（留空则使用“管理员”）: " ADMIN_DISPLAY_NAME
read -r -s -p "Webhook Secret（留空则自动生成）: " WEBHOOK_SECRET
echo
read -r -p "Worker 域名（留空则使用 workers.dev，例如 telegram-chatbot.yourname.workers.dev）: " WORKER_HOST

if [[ -z "${TELEGRAM_BOT_TOKEN}" || -z "${TELEGRAM_ADMIN_ID}" ]]; then
  echo "Telegram Bot Token 和管理员 ID 不能为空。"
  exit 1
fi

if ! [[ "${TELEGRAM_ADMIN_ID}" =~ ^[0-9]+$ ]]; then
  echo "管理员 ID 必须是数字。"
  exit 1
fi

if [[ -z "${WEBHOOK_SECRET}" ]]; then
  WEBHOOK_SECRET="$(openssl rand -hex 24 2>/dev/null || date +%s%N)"
fi

if ! [[ "${WEBHOOK_SECRET}" =~ ^[A-Za-z0-9_-]{1,256}$ ]]; then
  echo "Webhook Secret 只能包含 A-Z、a-z、0-9、_、-，长度 1-256。"
  exit 1
fi

if [[ ! -d "node_modules" ]]; then
  npm install --no-package-lock
fi

WRANGLER=(npx wrangler)

echo "检查 Cloudflare 登录状态..."
if ! "${WRANGLER[@]}" whoami >/dev/null 2>&1; then
  echo "Wrangler 尚未登录，请按提示登录 Cloudflare。"
  "${WRANGLER[@]}" login
fi

cat > wrangler.toml <<EOF
name = "${WORKER_NAME}"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF

echo "查找或创建 KV namespace..."
KV_LIST="$("${WRANGLER[@]}" kv namespace list 2>/dev/null || true)"
KV_ID="$(printf '%s' "${KV_LIST}" | node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const workerName = process.argv[1];
try {
  const namespaces = JSON.parse(input);
  const names = [`${workerName}-CHATBOT_KV`, "CHATBOT_KV"];
  const found = namespaces.find((namespace) => names.includes(namespace.title));
  if (found) process.stdout.write(found.id);
} catch {}
' "${WORKER_NAME}")"

if [[ -z "${KV_ID}" ]]; then
  KV_OUTPUT="$("${WRANGLER[@]}" kv namespace create CHATBOT_KV 2>&1)"
  echo "${KV_OUTPUT}"
  KV_ID="$(printf '%s\n' "${KV_OUTPUT}" | sed -n 's/.*id = "\([^"]*\)".*/\1/p' | tail -n 1)"
else
  echo "复用 KV namespace：${KV_ID}"
fi

if [[ -z "${KV_ID}" ]]; then
  echo "无法自动识别 KV namespace id。请把上方输出中的 id 填入 wrangler.toml 后重新运行。"
  exit 1
fi

cat > wrangler.toml <<EOF
name = "${WORKER_NAME}"
main = "src/index.js"
compatibility_date = "2026-07-01"

[[kv_namespaces]]
binding = "CHATBOT_KV"
id = "${KV_ID}"
EOF

put_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "${value}" | "${WRANGLER[@]}" secret put "${name}"
}

echo "写入 Worker secrets..."
put_secret "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"
put_secret "TELEGRAM_ADMIN_ID" "${TELEGRAM_ADMIN_ID}"
put_secret "ADMIN_DISPLAY_NAME" "${ADMIN_DISPLAY_NAME:-管理员}"
put_secret "WEBHOOK_SECRET" "${WEBHOOK_SECRET}"

echo "部署配置："
echo "- Worker 名称：${WORKER_NAME}"
echo "- KV namespace：${KV_ID}"
if [[ -n "${WORKER_HOST}" ]]; then
  echo "- 指定域名：${WORKER_HOST}"
else
  echo "- 域名：部署后自动识别 workers.dev 地址"
fi

echo "部署 Worker..."
DEPLOY_OUTPUT="$("${WRANGLER[@]}" deploy 2>&1)"
echo "${DEPLOY_OUTPUT}"

if [[ -z "${WORKER_HOST}" ]]; then
  WORKER_URL="$(printf '%s\n' "${DEPLOY_OUTPUT}" | sed -n 's/.*https:\/\/\([^[:space:]]*workers\.dev\).*/https:\/\/\1/p' | tail -n 1)"
else
  WORKER_HOST="${WORKER_HOST#https://}"
  WORKER_HOST="${WORKER_HOST#http://}"
  WORKER_HOST="${WORKER_HOST%/}"
  WORKER_URL="https://${WORKER_HOST}"
fi

if [[ -z "${WORKER_URL}" ]]; then
  echo "无法自动识别 Worker URL。请手动执行 Telegram setWebhook。"
  echo "Webhook Secret: ${WEBHOOK_SECRET}"
  exit 1
fi

WEBHOOK_URL="${WORKER_URL%/}/${WEBHOOK_SECRET}"

echo "设置 Telegram webhook..."
WEBHOOK_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  --data-urlencode "url=${WEBHOOK_URL}" \
  -d "secret_token=${WEBHOOK_SECRET}" \
  -d "drop_pending_updates=true")"
echo "${WEBHOOK_RESPONSE}"
if ! printf '%s' "${WEBHOOK_RESPONSE}" | grep -q '"ok":true'; then
  echo "Telegram setWebhook 返回失败，请检查 Bot Token 和 Worker URL。"
  exit 1
fi

USER_COMMANDS='[
  {"command":"start","description":"开始使用"},
  {"command":"help","description":"使用说明"},
  {"command":"about","description":"关于"},
  {"command":"ping","description":"检查在线"}
]'
ADMIN_COMMANDS='[
  {"command":"start","description":"开始使用"},
  {"command":"help","description":"使用说明"},
  {"command":"about","description":"关于"},
  {"command":"ping","description":"检查在线"},
  {"command":"status","description":"运行状态"},
  {"command":"log","description":"最近日志"},
  {"command":"stop","description":"暂停转发"},
  {"command":"resume","description":"恢复转发"},
  {"command":"ban","description":"封禁用户"},
  {"command":"unban","description":"解除封禁"},
  {"command":"banlist","description":"封禁列表"},
  {"command":"who","description":"识别用户ID"},
  {"command":"restart","description":"重启服务"}
]'

echo "同步 Telegram 命令菜单..."
COMMAND_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  --data-urlencode "commands=${USER_COMMANDS}" \
  --data-urlencode 'scope={"type":"default"}')"
echo "${COMMAND_RESPONSE}"
if ! printf '%s' "${COMMAND_RESPONSE}" | grep -q '"ok":true'; then
  echo "同步默认命令菜单失败。"
  exit 1
fi

ADMIN_COMMAND_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  --data-urlencode "commands=${ADMIN_COMMANDS}" \
  --data-urlencode "scope={\"type\":\"chat\",\"chat_id\":${TELEGRAM_ADMIN_ID}}")"
echo "${ADMIN_COMMAND_RESPONSE}"
if ! printf '%s' "${ADMIN_COMMAND_RESPONSE}" | grep -q '"ok":true'; then
  echo "同步管理员命令菜单失败。"
  exit 1
fi

echo "Cloudflare Workers 部署完成。"
echo "Worker URL: ${WORKER_URL}"
echo "Telegram Webhook URL: ${WEBHOOK_URL}"
