#!/usr/bin/env bash
#
# =============================================================================
# Telegram 双向聊天机器人 —— Cloudflare Workers 一键部署脚本
# =============================================================================
#
# 这个脚本会把机器人部署到 Cloudflare Workers 上（无服务器，不用自己养 VPS）：
#
#   1. 检查运行环境（Node.js、npm、curl）
#   2. 收集必要配置（Worker 名称、Bot Token、管理员 ID、域名）
#   3. 部署前确认（先给你看一张汇总表，确认了才动手）
#   4. 安装依赖（Wrangler，Cloudflare 官方命令行工具）
#   5. 登录 Cloudflare 账号（第一次需要浏览器授权）
#   6. 查找或创建 KV namespace（用来保存封禁列表、消息映射、暂停状态）
#   7. 生成 wrangler.toml 并写入 Worker secrets
#   8. 部署 Worker 到 Cloudflare
#   9. 设置 Telegram webhook 并同步命令菜单
#
# 适用系统：macOS / Linux / Windows（WSL），需要 Node.js 18+ 和 npm。
#
# 使用方法：
#   在 worker 目录下运行：
#     cd worker
#     bash deploy.sh
#
# 部署完成后：
#   - 机器人运行在 Cloudflare 的服务器上，本地电脑可以关机，不影响运行。
#   - 以后改代码、改配置，再跑一次本脚本即可重新部署。
#   - 查看日志：npx wrangler tail，或在 Cloudflare 控制台查看。
#
# 开始之前，请先准备好下面两样东西：
#
#   1. Telegram Bot Token
#      在 Telegram 里找到 @BotFather，发送 /newbot 按提示创建一个机器人，
#      创建成功后会得到一串 Token，形如 123456789:AAE...。
#
#   2. 管理员 Telegram 数字 ID
#      在 Telegram 里找到 @userinfobot，随便发一条消息，它会回复你的数字 ID。
#      注意：这里要的是纯数字 ID，不是 @用户名。
#
# 还需要一个 Cloudflare 账号（免费版即可）：
#   没有账号先去 https://dash.cloudflare.com/sign-up 注册一个。
#   部署时脚本会请你登录授权；如果是在没有浏览器的服务器上运行，
#   按提示把登录链接复制到自己的浏览器里打开即可。
#
# 关于域名：
#   不填域名时，Worker 使用 Cloudflare 分配的 workers.dev 地址，例如
#   telegram-chatbot.你的名字.workers.dev，部署后自动识别。
#   如果填了自己的域名（例如 bot.example.com），该域名必须已经托管在
#   Cloudflare 上（DNS 在 Cloudflare），脚本会把它绑定到 Worker。
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

# ── 输出格式 ────────────────────────────────────────────────────────
step()  { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
info()  { echo "  → $1"; }
ok()    { echo "  ✓ $1"; }
warn()  { echo "  ! $1"; }

# 报错并退出。$1 是要显示的错误信息。
die() {
  echo
  echo "  ✗ 部署失败：$1"
  echo "  请根据上面的提示修正后，重新运行部署脚本。"
  exit 1
}

# ── 步骤 1：检查运行环境 ────────────────────────────────────────────
step "步骤 1/9：检查运行环境"

# Node.js 和 npm：用来安装和运行 Wrangler。
if ! command -v node >/dev/null 2>&1; then
  die "没有找到 node，请先安装 Node.js 18+（https://nodejs.org），再重新运行"
fi
if ! command -v npm >/dev/null 2>&1; then
  die "没有找到 npm，请先安装 Node.js 18+（npm 随 Node.js 一起安装），再重新运行"
fi
# Wrangler 4 要求 Node.js 18+，版本太低到装依赖时才报错，不如现在就说清楚。
NODE_VERSION="$(node --version 2>/dev/null || echo "v0")"
NODE_MAJOR="$(printf '%s' "${NODE_VERSION}" | sed 's/^v//; s/\..*//')"
if ! [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] || (( NODE_MAJOR < 18 )); then
  die "Node.js 版本太低：当前是 ${NODE_VERSION}，需要 18+（https://nodejs.org）"
fi
ok "已找到 Node.js $(node --version) 和 npm"

# curl：用来调用 Telegram 接口设置 webhook 和命令菜单。
if ! command -v curl >/dev/null 2>&1; then
  die "没有找到 curl，请先安装 curl 再重新运行"
fi
ok "已找到 curl"

# 必须在 worker 目录运行：这里要有 package.json 和 src/index.js。
if [[ ! -f "package.json" ]]; then
  die "请在 worker 目录下运行此脚本（cd worker && bash deploy.sh）"
fi
if [[ ! -f "src/index.js" ]]; then
  die "没有找到 src/index.js，请确认 worker 目录完整"
fi
ok "正在 worker 目录运行"

# ── 步骤 2：收集配置 ────────────────────────────────────────────────
step "步骤 2/9：收集配置"
echo "  下面需要你提供几项配置，带 [默认] 的可以直接按回车跳过。"
echo

# --- Worker 名称（只能用小写字母、数字和连字符，Wrangler 的要求）---
echo "  ① Cloudflare Worker 名称"
echo "     只能用小写字母、数字和连字符，例如 telegram-chatbot。"
while true; do
  read -r -p "     请输入 Worker 名称 [telegram-chatbot]: " WORKER_NAME || die "输入被中断，部署已取消"
  WORKER_NAME="${WORKER_NAME:-telegram-chatbot}"
  if [[ "${WORKER_NAME}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    break
  fi
  warn "Worker 名称只能用小写字母、数字和连字符，且不能以连字符开头，请重新输入"
done

# --- Bot Token（输入时不回显，顺手做个格式检查）---
echo "  ② Telegram Bot Token"
echo "     获取方法：在 Telegram 里找 @BotFather，发送 /newbot 创建机器人。"
while true; do
  read -r -s -p "     请输入 Bot Token: " TELEGRAM_BOT_TOKEN || die "输入被中断，部署已取消"
  echo
  # 去掉所有空白字符，避免复制粘贴时多带了空格导致 Token 失效。
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN//[[:space:]]/}"
  if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
    warn "Bot Token 不能为空，请重新输入"
    continue
  fi
  # Token 正常是「数字:一长串」的样子，先做个格式检查，贴错了马上发现。
  if [[ ! "${TELEGRAM_BOT_TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    warn "Token 格式看起来不对（正常是 数字:一长串），请检查是不是贴错了"
    continue
  fi
  break
done

# --- 管理员数字 ID（只接受纯数字，可反复输入直到正确）---
echo "  ③ 管理员 Telegram 数字 ID"
echo "     获取方法：在 Telegram 里找 @userinfobot，随便发一条消息，它会回复你的数字 ID。"
while true; do
  read -r -p "     请输入管理员数字 ID: " TELEGRAM_ADMIN_ID || die "输入被中断，部署已取消"
  if [[ "${TELEGRAM_ADMIN_ID}" =~ ^[0-9]+$ ]]; then
    break
  fi
  warn "管理员 ID 必须是纯数字（不是 @用户名），请重新输入"
done

# --- 管理员显示名（可选，留空则用“管理员”）---
echo "  ④ 管理员显示名（可选）"
echo "     机器人欢迎语和关于页面里会用到，留空则使用“管理员”。"
read -r -p "     管理员显示名 [留空使用“管理员”]: " ADMIN_DISPLAY_NAME || die "输入被中断，部署已取消"
ADMIN_DISPLAY_NAME="${ADMIN_DISPLAY_NAME:-管理员}"

# --- Webhook Secret（可选，留空则自动生成）---
echo "  ⑤ Webhook Secret（可选）"
echo "     用来校验推送确实来自 Telegram。留空则自动生成一串随机的。"
read -r -s -p "     Webhook Secret [留空自动生成]: " WEBHOOK_SECRET || die "输入被中断，部署已取消"
echo
if [[ -z "${WEBHOOK_SECRET}" ]]; then
  # openssl 不可用时用 /dev/urandom 兜底（macOS 的 date 不支持 %N，别用它拼随机数）
  WEBHOOK_SECRET="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  info "已自动生成 Webhook Secret"
fi
if ! [[ "${WEBHOOK_SECRET}" =~ ^[A-Za-z0-9_-]{1,256}$ ]]; then
  die "Webhook Secret 只能包含 A-Z、a-z、0-9、_、-，长度 1-256"
fi

# --- Worker 域名（可选，留空用 workers.dev）---
echo "  ⑥ Worker 域名（可选）"
echo "     留空则使用 Cloudflare 分配的 workers.dev 地址，例如"
echo "     telegram-chatbot.你的名字.workers.dev。"
echo "     如果填自己的域名（例如 bot.example.com），该域名必须已经托管在"
echo "     Cloudflare 上（DNS 在 Cloudflare），否则部署时会报错。"
read -r -p "     Worker 域名 [留空使用 workers.dev]: " WORKER_HOST || die "输入被中断，部署已取消"
# 去掉可能带上的协议前缀和末尾斜杠，只留主机名。
WORKER_HOST="${WORKER_HOST#https://}"
WORKER_HOST="${WORKER_HOST#http://}"
WORKER_HOST="${WORKER_HOST%/}"
WORKER_HOST="${WORKER_HOST//[[:space:]]/}"
# 域名只能是纯主机名，不能带路径、端口或空格，否则写进 routes 到部署时才报错
if [[ -n "${WORKER_HOST}" ]]; then
  if [[ "${WORKER_HOST}" == */* || "${WORKER_HOST}" == *:* ]]; then
    die "Worker 域名只能填纯主机名（例如 bot.example.com），不能带路径或端口"
  fi
  if ! [[ "${WORKER_HOST}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "Worker 域名格式不对，请填写纯主机名（例如 bot.example.com）"
  fi
fi

# ── 步骤 3：部署前确认 ──────────────────────────────────────────────
step "步骤 3/9：部署前确认"
echo "  请确认以下部署信息是否正确："
echo
echo "    Worker 名称：  ${WORKER_NAME}"
if [[ -n "${WORKER_HOST}" ]]; then
  echo "    Worker 域名：  https://${WORKER_HOST}（须已托管在 Cloudflare）"
else
  echo "    Worker 域名：  （留空，部署后自动识别 workers.dev 地址）"
fi
echo "    管理员 ID：   ${TELEGRAM_ADMIN_ID}"
echo "    管理员显示名：${ADMIN_DISPLAY_NAME}"
echo "    KV 存储：     自动查找或创建（保存封禁列表、消息映射、暂停状态）"
echo
echo "  注意：Bot Token 和 Webhook Secret 不会显示在这里，"
echo "  只会以加密的 secret 形式保存在 Cloudflare，不会写入仓库文件。"
echo
# 输入中断（Ctrl-D 或输入流结束）时按取消处理，不继续部署。
read -r -p "  确认开始部署吗？[Y/n]: " CONFIRM || { echo; echo "  输入被中断，已取消部署，没有做任何修改。"; exit 0; }
if [[ "${CONFIRM}" =~ ^[Nn] ]]; then
  echo
  echo "  已取消部署，没有做任何修改。"
  exit 0
fi

# ── 步骤 4：安装依赖 ────────────────────────────────────────────────
step "步骤 4/9：安装依赖"
if [[ ! -d "node_modules" ]]; then
  info "正在安装依赖（Wrangler 等，需要几分钟）……"
  npm install --no-package-lock || die "依赖安装失败，请检查网络后重试"
else
  info "依赖已安装，跳过 npm install"
fi
# 直接用本地安装的 Wrangler，不经过 npx，避免它去网上再下载一份。
WRANGLER="${SCRIPT_DIR}/node_modules/.bin/wrangler"
if [[ ! -x "${WRANGLER}" ]]; then
  die "没有找到本地 Wrangler，请删除 node_modules 后重新运行"
fi
WRANGLER_VERSION="$("${WRANGLER}" --version 2>/dev/null | head -n 1 || true)"
ok "依赖就绪：Wrangler ${WRANGLER_VERSION:-（版本未知）}"

# ── 步骤 5：登录 Cloudflare ─────────────────────────────────────────
step "步骤 5/9：登录 Cloudflare"
info "正在检查 Cloudflare 登录状态……"
if ! "${WRANGLER}" whoami >/dev/null 2>&1; then
  echo "  Wrangler 尚未登录，请按提示完成登录授权。"
  echo "  如果是在没有浏览器的服务器上运行，把下面打印出的登录链接"
  echo "  复制到自己的浏览器里打开即可。"
  "${WRANGLER}" login || die "Cloudflare 登录失败，请重试"
fi
ok "已登录 Cloudflare"

# ── 步骤 6：准备 KV 与 wrangler.toml ────────────────────────────────
step "步骤 6/9：准备 KV namespace 与配置文件"
info "正在查找已有的 KV namespace……"

# wrangler kv namespace list 正常返回 JSON 数组；如果输出格式不对，
# 下面这段 Node 代码还会按行扫描兜底，避免每次重跑都新建一个 KV。
KV_LIST="$("${WRANGLER}" kv namespace list 2>/dev/null || true)"
KV_ID="$(printf '%s' "${KV_LIST}" | node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const workerName = process.argv[1];
const names = [`${workerName}-CHATBOT_KV`, "CHATBOT_KV"];
let foundId = "";
try {
  const namespaces = JSON.parse(input);
  const found = namespaces.find((namespace) => names.includes(namespace.title));
  if (found) foundId = found.id;
} catch {}
if (!foundId) {
  for (const line of input.split("\n")) {
    if (names.some((name) => line.includes(name))) {
      const match = line.match(/([0-9a-f]{32})/);
      if (match) { foundId = match[1]; break; }
    }
  }
}
if (foundId) process.stdout.write(foundId);
' "${WORKER_NAME}")"

if [[ -z "${KV_ID}" ]]; then
  info "没有找到已有的 KV，正在创建一个新的……"
  if ! KV_OUTPUT="$("${WRANGLER}" kv namespace create CHATBOT_KV 2>&1)"; then
    echo "${KV_OUTPUT}"
    die "创建 KV namespace 失败，请检查上面的输出"
  fi
  echo "${KV_OUTPUT}"
  # 先按完整格式匹配，再用宽松格式兜底。
  KV_ID="$(printf '%s\n' "${KV_OUTPUT}" | sed -n 's/.*binding = "CHATBOT_KV", id = "\([^"]*\)".*/\1/p' | tail -n 1)"
  if [[ -z "${KV_ID}" ]]; then
    KV_ID="$(printf '%s\n' "${KV_OUTPUT}" | sed -n 's/.*id = "\([^"]*\)".*/\1/p' | tail -n 1)"
  fi
else
  ok "复用已有的 KV namespace：${KV_ID}"
fi

if [[ -z "${KV_ID}" ]]; then
  die "无法识别 KV namespace id。请把上方输出中的 id 填入 wrangler.toml 后重新运行"
fi

# 生成 wrangler.toml。填了自定义域名时把它绑定到 Worker；
# 域名必须已托管在 Cloudflare，否则这一步部署会报错。
if [[ -n "${WORKER_HOST}" ]]; then
  cat > wrangler.toml <<EOF
name = "${WORKER_NAME}"
main = "src/index.js"
compatibility_date = "2026-07-01"

routes = [{ pattern = "${WORKER_HOST}", custom_domain = true }]

[[kv_namespaces]]
binding = "CHATBOT_KV"
id = "${KV_ID}"
EOF
else
  cat > wrangler.toml <<EOF
name = "${WORKER_NAME}"
main = "src/index.js"
compatibility_date = "2026-07-01"

[[kv_namespaces]]
binding = "CHATBOT_KV"
id = "${KV_ID}"
EOF
fi
ok "配置文件已生成：wrangler.toml（KV id：${KV_ID}）"

# ── 步骤 7：写入 Worker secrets ─────────────────────────────────────
step "步骤 7/9：写入 Worker secrets"
info "正在把 Token 等配置以加密 secret 的形式写入 Cloudflare……"

# 从标准输入读取 secret 内容，避免出现在命令行参数和 shell 历史里。
put_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "${value}" | "${WRANGLER}" secret put "${name}" || die "写入 secret ${name} 失败"
}

put_secret "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"
put_secret "TELEGRAM_ADMIN_ID" "${TELEGRAM_ADMIN_ID}"
put_secret "ADMIN_DISPLAY_NAME" "${ADMIN_DISPLAY_NAME}"
put_secret "WEBHOOK_SECRET" "${WEBHOOK_SECRET}"
ok "4 个 secrets 已写入（Token、管理员 ID、显示名、Webhook Secret）"

# ── 步骤 8：部署 Worker ─────────────────────────────────────────────
step "步骤 8/9：部署 Worker"
info "正在部署到 Cloudflare……"
if ! DEPLOY_OUTPUT="$("${WRANGLER}" deploy 2>&1)"; then
  echo "${DEPLOY_OUTPUT}"
  die "Worker 部署失败，请检查上面的输出"
fi
echo "${DEPLOY_OUTPUT}"

# 确定 Worker 的访问地址。填了自定义域名就直接用它；
# 否则从部署输出里识别 workers.dev 地址。
if [[ -n "${WORKER_HOST}" ]]; then
  WORKER_URL="https://${WORKER_HOST}"
else
  WORKER_URL="$(printf '%s\n' "${DEPLOY_OUTPUT}" | sed -n 's/.*https:\/\/\([^[:space:]]*workers\.dev\).*/https:\/\/\1/p' | tail -n 1)"
fi

if [[ -z "${WORKER_URL}" ]]; then
  echo "  无法自动识别 Worker URL，部署本身可能已成功。"
  echo "  请去 Cloudflare 控制台查看 Worker 地址，再手动设置 Telegram webhook。"
  echo "  Webhook Secret 已经以加密 secret 的形式保存在 Cloudflare，不会显示在这里；"
  echo "  如需更换，重新运行 deploy.sh（留空会自动生成新的）即可。"
  exit 1
fi
ok "Worker 已部署：${WORKER_URL}"

# ── 步骤 9：设置 Telegram webhook 与命令菜单 ────────────────────────
step "步骤 9/9：设置 Telegram webhook 与命令菜单"

# Webhook 地址把 Secret 放在路径末尾；同时用 secret_token 传一份，
# Worker 两边都会校验，任意一边对上就算通过。
WEBHOOK_URL="${WORKER_URL%/}/${WEBHOOK_SECRET}"

info "正在设置 Telegram webhook：${WORKER_URL%/}/<secret>"
if ! WEBHOOK_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  --data-urlencode "url=${WEBHOOK_URL}" \
  -d "secret_token=${WEBHOOK_SECRET}" \
  -d "drop_pending_updates=true")"; then
  die "设置 Telegram webhook 失败，请检查 Bot Token 和 Worker URL 是否正确"
fi
echo "${WEBHOOK_RESPONSE}"
if ! printf '%s' "${WEBHOOK_RESPONSE}" | grep -q '"ok":true'; then
  die "Telegram setWebhook 返回失败，请检查 Bot Token 和 Worker URL"
fi
ok "Telegram webhook 已设置"

# 命令菜单：用户和管理员看到的不一样。注意 Worker 版不支持 /log 和 /restart
#（没有 systemd），所以菜单里不放这两项，免得点了只回一句“不支持”。
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
  {"command":"stop","description":"暂停转发"},
  {"command":"resume","description":"恢复转发"},
  {"command":"ban","description":"封禁用户"},
  {"command":"unban","description":"解除封禁"},
  {"command":"banlist","description":"封禁列表"},
  {"command":"who","description":"识别用户ID"}
]'

info "正在同步 Telegram 命令菜单……"
if ! COMMAND_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  --data-urlencode "commands=${USER_COMMANDS}" \
  --data-urlencode 'scope={"type":"default"}')"; then
  die "同步默认命令菜单失败，请检查 Bot Token"
fi
echo "${COMMAND_RESPONSE}"
if ! printf '%s' "${COMMAND_RESPONSE}" | grep -q '"ok":true'; then
  die "同步默认命令菜单失败"
fi

if ! ADMIN_COMMAND_RESPONSE="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  --data-urlencode "commands=${ADMIN_COMMANDS}" \
  --data-urlencode "scope={\"type\":\"chat\",\"chat_id\":${TELEGRAM_ADMIN_ID}}")"; then
  die "同步管理员命令菜单失败，请检查 Bot Token 和管理员 ID"
fi
echo "${ADMIN_COMMAND_RESPONSE}"
if ! printf '%s' "${ADMIN_COMMAND_RESPONSE}" | grep -q '"ok":true'; then
  die "同步管理员命令菜单失败"
fi
ok "命令菜单已同步"

# ── 完成 ────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Cloudflare Workers 部署完成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Worker 地址：  ${WORKER_URL}"
echo "  Webhook 地址： ${WORKER_URL%/}/<secret>（Secret 不在这里显示）"
echo "  KV namespace： ${KV_ID}"
echo
echo "  试一试："
echo "    在 Telegram 里给你的机器人发一条消息，机器人会把它转给你；"
echo "    你直接回复那条消息，就能回给对方。"
echo
echo "  常用命令："
echo "    查看日志：  npx wrangler tail"
echo "    重新部署：  bash deploy.sh（改代码、改配置后都用它）"
echo "    删除 Worker：npx wrangler delete --name ${WORKER_NAME}"
echo
echo "  注意："
echo "    - 部署完成后本地电脑可以关机，机器人运行在 Cloudflare 上。"
echo "    - 但请保留 worker 目录（代码和 wrangler.toml），以后改东西还靠它。"
echo "    - 想换 Token 或管理员 ID，改好 secret 后重新跑一次本脚本，"
echo "      或用 npx wrangler secret put <名字> 单独改一项。"
echo
