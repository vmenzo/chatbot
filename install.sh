#!/usr/bin/env bash
#
# =============================================================================
# Telegram 双向聊天机器人 —— 一键安装脚本
# =============================================================================
#
# 这个脚本会在一台 Debian / Ubuntu 服务器上完成机器人的全部安装与配置：
#
#   1. 检查运行环境（root 权限、systemd、网络工具）
#   2. 收集必要配置（Bot Token、管理员 ID、部署模式）
#   3. 安装系统依赖（Python 3、虚拟环境工具等）
#   4. 下载程序文件（chatbot.py 及依赖清单）
#   5. 创建 Python 虚拟环境并安装依赖
#   6. 写入配置文件（Token 等敏感信息只保存在本机）
#   7. 注册 systemd 服务并启动机器人
#
# 适用系统：Debian 11+ / Ubuntu 22.04+（需要 Python 3.9+，需要 systemd，需要 root 权限）
#
# 使用方法：
#
#   一行安装（推荐）：
#     sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh)"
#
#   本地安装（已下载仓库时）：
#     sudo bash install.sh
#
# 安装完成后：
#   查看运行状态：systemctl status chatbot.service
#   实时查看日志：journalctl -u chatbot.service -f
#   重启机器人：  systemctl restart chatbot.service
#   停止机器人：  systemctl stop chatbot.service
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
# =============================================================================

set -euo pipefail

# ── 安装位置与文件名（一般不需要修改）───────────────────────────────
APP_DIR="/opt/chatbot"                            # 程序安装目录
SERVICE_NAME="chatbot.service"                    # systemd 服务名
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}" # systemd 服务文件
ENV_FILE="/etc/chatbot.env"                       # 配置文件（权限 600，仅 root 可读）

# 程序文件的下载地址。默认从 GitHub 拉取；如果你在本地已有这些文件，
# 脚本会优先使用本地文件，不再下载。
RAW_BASE="${CHATBOT_RAW_BASE:-https://raw.githubusercontent.com/vmenzo/chatbot/main}"

# ── 输出格式 ────────────────────────────────────────────────────────
# 步骤标题：[步骤 1/8] 正在检查运行环境……
step()  { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
info()  { echo "  → $1"; }
ok()    { echo "  ✓ $1"; }
warn()  { echo "  ! $1"; }

# 报错并退出。$1 是要显示的错误信息。
die() {
  echo
  echo "  ✗ 安装失败：$1"
  echo "  请根据上面的提示修正后，重新运行安装脚本。"
  exit 1
}

# ── 步骤 1：检查运行环境 ────────────────────────────────────────────
step "步骤 1/8：检查运行环境"

# 必须用 root 运行：安装要写 /opt、/etc，还要注册系统服务。
if [[ "${EUID}" -ne 0 ]]; then
  die "请用 root 权限运行，例如：sudo bash install.sh"
fi
ok "当前用户是 root"

# 必须有 systemd：机器人靠 systemd 实现开机自启和异常重启。
if ! command -v systemctl >/dev/null 2>&1; then
  die "没有找到 systemctl，本脚本需要带 systemd 的系统（Debian 11+ / Ubuntu 22.04+）"
fi
ok "已找到 systemd"

# curl 用来下载程序文件。
if ! command -v curl >/dev/null 2>&1; then
  warn "没有找到 curl，稍后安装系统依赖时会自动装上"
fi

# ── 步骤 2：收集配置 ────────────────────────────────────────────────
step "步骤 2/8：收集配置"
echo "  下面需要你提供几项配置，带 [默认] 的可以直接按回车跳过。"
echo

# --- Bot Token（输入时不回显）---
echo "  ① Telegram Bot Token"
echo "     获取方法：在 Telegram 里找 @BotFather，发送 /newbot 创建机器人。"
while true; do
  read -r -s -p "     请输入 Bot Token: " BOT_TOKEN || die "输入被中断，安装已取消"
  echo
  # 去掉所有空白字符，避免复制粘贴时多带了空格导致 Token 失效。
  BOT_TOKEN="${BOT_TOKEN//[[:space:]]/}"
  if [[ -z "${BOT_TOKEN}" ]]; then
    warn "Bot Token 不能为空，请重新输入"
    continue
  fi
  # Token 正常是「数字:一长串」的样子，先做个格式检查，贴错了马上发现。
  if [[ ! "${BOT_TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    warn "Token 格式看起来不对（正常是 数字:一长串），请检查是不是贴错了"
    continue
  fi
  break
done

# --- 管理员数字 ID（只接受纯数字，可反复输入直到正确）---
echo "  ② 管理员 Telegram 数字 ID"
echo "     获取方法：在 Telegram 里找 @userinfobot，随便发一条消息，它会回复你的数字 ID。"
while true; do
  read -r -p "     请输入管理员数字 ID: " ADMIN_ID || die "输入被中断，安装已取消"
  if [[ "${ADMIN_ID}" =~ ^[0-9]+$ ]]; then
    break
  fi
  warn "管理员 ID 必须是纯数字（不是 @用户名），请重新输入"
done

# --- 管理员显示名（可选，留空则自动用 Telegram 上的名字）---
echo "  ③ 管理员显示名（可选）"
echo "     机器人欢迎语和关于页面里会用到，留空则自动识别你的 Telegram 名字。"
read -r -p "     管理员显示名 [留空自动识别]: " ADMIN_DISPLAY_NAME || die "输入被中断，安装已取消"

# --- 部署模式 ---
echo "  ④ 部署模式（二选一）"
echo "     1) long polling（默认）"
echo "        机器人主动去 Telegram 拉取消息。不需要域名、不需要开放端口，"
echo "        适合普通 VPS，是最省事的选择。"
echo "     2) webhook"
echo "        Telegram 把消息推送到你的服务器。需要一个公网 HTTPS 域名，"
echo "        并且能反向代理到本机端口，适合已有域名的服务器。"
read -r -p "     请选择 [1/2，默认 1]: " MODE_CHOICE || die "输入被中断，安装已取消"

CHATBOT_MODE="polling"
WEBHOOK_LISTEN="0.0.0.0"
WEBHOOK_PORT="8080"
WEBHOOK_PATH="telegram"
WEBHOOK_URL=""
WEBHOOK_SECRET=""

case "${MODE_CHOICE:-1}" in
  1)
    CHATBOT_MODE="polling"
    ;;
  2)
    CHATBOT_MODE="webhook"
    echo
    echo "  Webhook 模式需要下面几项配置："
    read -r -p "     本机监听地址 [默认 0.0.0.0]: " WEBHOOK_LISTEN_INPUT || die "输入被中断，安装已取消"
    read -r -p "     本机监听端口 [默认 8080]: " WEBHOOK_PORT_INPUT || die "输入被中断，安装已取消"
    read -r -p "     Webhook 路径 [默认 telegram]: " WEBHOOK_PATH_INPUT || die "输入被中断，安装已取消"
    WEBHOOK_LISTEN="${WEBHOOK_LISTEN_INPUT:-0.0.0.0}"
    WEBHOOK_PORT="${WEBHOOK_PORT_INPUT:-8080}"
    WEBHOOK_PATH="${WEBHOOK_PATH_INPUT:-telegram}"
    # 去掉路径首尾多余的斜杠，例如 "/telegram/" 写成 "telegram"。
    WEBHOOK_PATH="${WEBHOOK_PATH#/}"
    WEBHOOK_PATH="${WEBHOOK_PATH%/}"
    if [[ -z "${WEBHOOK_PATH}" ]]; then
      die "Webhook 路径不能为空"
    fi
    if ! [[ "${WEBHOOK_PORT}" =~ ^[0-9]+$ ]]; then
      die "Webhook 端口必须是数字"
    fi
    echo "     公网地址：填域名或完整 URL，例如 example.com 或 https://example.com/telegram"
    read -r -p "     请输入公网域名或完整 URL: " WEBHOOK_URL_INPUT || die "输入被中断，安装已取消"
    if [[ -z "${WEBHOOK_URL_INPUT}" ]]; then
      die "Webhook 模式必须填写公网域名或完整 URL"
    fi
    # 只填了域名时自动补成 https://域名/路径；填了完整 URL 则直接使用。
    WEBHOOK_URL="${WEBHOOK_URL_INPUT%/}"
    if [[ "${WEBHOOK_URL}" != http://* && "${WEBHOOK_URL}" != https://* ]]; then
      WEBHOOK_URL="https://${WEBHOOK_URL}"
    fi
    if [[ "${WEBHOOK_URL}" != */"${WEBHOOK_PATH}" ]]; then
      WEBHOOK_URL="${WEBHOOK_URL}/${WEBHOOK_PATH}"
    fi
    if [[ "${WEBHOOK_URL}" != https://* ]]; then
      die "Webhook URL 必须是 HTTPS 地址，Telegram 不接受 HTTP"
    fi
    echo "     Webhook Secret（可选）：用于校验推送确实来自 Telegram，留空则不校验。"
    read -r -s -p "     Webhook Secret [留空不设置]: " WEBHOOK_SECRET || die "输入被中断，安装已取消"
    echo
    ;;
  *)
    die "模式只能选择 1 或 2"
    ;;
esac

# ── 步骤 3：安装前确认 ──────────────────────────────────────────────
step "步骤 3/8：安装前确认"
echo "  请确认以下安装信息是否正确："
echo
echo "    部署模式：  ${CHATBOT_MODE}"
echo "    安装目录：  ${APP_DIR}"
echo "    配置文件：  ${ENV_FILE}（权限 600，仅 root 可读）"
echo "    服务名称：  ${SERVICE_NAME}"
echo "    管理员 ID： ${ADMIN_ID}"
if [[ -n "${ADMIN_DISPLAY_NAME}" ]]; then
  echo "    管理员显示名：${ADMIN_DISPLAY_NAME}"
else
  echo "    管理员显示名：（留空，自动识别）"
fi
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  echo "    Webhook 地址：${WEBHOOK_URL}"
  echo "    本机监听：  ${WEBHOOK_LISTEN}:${WEBHOOK_PORT}/${WEBHOOK_PATH}"
fi
echo "    安装文件：  chatbot.py、requirements.txt"
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  echo "              （Webhook 模式额外安装 requirements-webhook.txt）"
fi
echo
echo "  注意：Bot Token 不会显示在这里，也不会写入任何公开文件，"
echo "  只保存在本机的配置文件 ${ENV_FILE} 中。"
echo
# 输入中断（Ctrl-D 或输入流结束）时按取消处理，不继续安装。
read -r -p "  确认开始安装吗？[Y/n]: " CONFIRM || { echo; echo "  输入被中断，已取消安装，没有做任何修改。"; exit 0; }
if [[ "${CONFIRM}" =~ ^[Nn] ]]; then
  echo
  echo "  已取消安装，没有做任何修改。"
  exit 0
fi

# ── 步骤 4：安装系统依赖 ────────────────────────────────────────────
step "步骤 4/8：安装系统依赖"
info "正在更新软件包列表并安装 Python 3、curl 等依赖（需要几分钟）……"
apt-get update || die "软件包列表更新失败，请检查网络后重试"
apt-get install -y ca-certificates curl python3 python3-venv python3-pip || die "系统依赖安装失败，请检查网络后重试"
ok "系统依赖安装完成"

# ── 步骤 5：下载程序文件 ────────────────────────────────────────────
step "步骤 5/8：下载程序文件"

mkdir -p "${APP_DIR}"

# 下载单个程序文件。如果脚本旁边就有这个文件（本地安装），直接复制；
# 否则从 GitHub 下载。下载失败会直接报错退出。
install_project_file() {
  local filename="$1"
  local source_file
  source_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/${filename}"

  if [[ -f "${source_file}" ]]; then
    info "使用本地文件：${filename}"
    cp "${source_file}" "${APP_DIR}/${filename}"
    return
  fi

  if [[ -z "${RAW_BASE}" ]]; then
    die "找不到 ${filename}。如果用 GitHub 一行安装，请这样运行：sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh)\""
  fi

  info "正在从 GitHub 下载：${filename}"
  curl -fsSL "${RAW_BASE%/}/${filename}" -o "${APP_DIR}/${filename}"
}

install_project_file "chatbot.py"
install_project_file "requirements.txt"
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  install_project_file "requirements-webhook.txt"
fi
ok "程序文件已就绪：${APP_DIR}"

# ── 步骤 6：创建 Python 虚拟环境并安装依赖 ──────────────────────────
step "步骤 6/8：安装 Python 依赖"
info "正在创建虚拟环境：${APP_DIR}/venv"
python3 -m venv "${APP_DIR}/venv"
info "正在安装依赖（需要几分钟）……"
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements-webhook.txt"
fi
ok "Python 依赖安装完成"

# ── 步骤 7：写入配置文件 ────────────────────────────────────────────
step "步骤 7/8：写入配置文件"

# 把值包在双引号里再写入，避免特殊字符破坏配置格式。
escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

cat > "${ENV_FILE}" <<EOF
TELEGRAM_BOT_TOKEN=$(escape_env_value "${BOT_TOKEN}")
TELEGRAM_ADMIN_ID=${ADMIN_ID}
CHATBOT_SERVICE_NAME=$(escape_env_value "${SERVICE_NAME}")
CHATBOT_DATA_DIR=$(escape_env_value "${APP_DIR}")
ADMIN_DISPLAY_NAME=$(escape_env_value "${ADMIN_DISPLAY_NAME}")
CHATBOT_MODE=$(escape_env_value "${CHATBOT_MODE}")
CHATBOT_WEBHOOK_LISTEN=$(escape_env_value "${WEBHOOK_LISTEN}")
CHATBOT_WEBHOOK_PORT=${WEBHOOK_PORT}
CHATBOT_WEBHOOK_PATH=$(escape_env_value "${WEBHOOK_PATH}")
CHATBOT_WEBHOOK_URL=$(escape_env_value "${WEBHOOK_URL}")
CHATBOT_WEBHOOK_SECRET=$(escape_env_value "${WEBHOOK_SECRET}")
EOF
chmod 600 "${ENV_FILE}"
ok "配置文件已写入：${ENV_FILE}（仅 root 可读）"

# ── 步骤 8：注册并启动服务 ──────────────────────────────────────────
step "步骤 8/8：注册并启动服务"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Telegram Chatbot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/chatbot.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
ok "服务文件已写入：${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# 启动后检查服务是否真的在运行，避免装完才发现起不来。
# 慢机器上 Python 启动需要几秒，最多等 15 秒，每秒检查一次。
info "正在等待服务启动……"
for _ in $(seq 1 15); do
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    break
  fi
  sleep 1
done
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "服务已启动并正在运行"
else
  echo
  echo "  ✗ 服务启动失败，最近的日志如下："
  journalctl -u "${SERVICE_NAME}" --no-pager -n 20 -o cat || true
  die "请检查上面的日志，修正问题后运行 systemctl restart ${SERVICE_NAME} 重试"
fi

# ── 完成 ────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ 安装完成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  部署模式：  ${CHATBOT_MODE}"
echo "  安装目录：  ${APP_DIR}"
echo "  配置文件：  ${ENV_FILE}"
echo
echo "  常用命令："
echo "    查看状态：  systemctl status ${SERVICE_NAME}"
echo "    查看日志：  journalctl -u ${SERVICE_NAME} -f"
echo "    重启服务：  systemctl restart ${SERVICE_NAME}"
echo "    停止服务：  systemctl stop ${SERVICE_NAME}"
echo
echo "  使用方法："
echo "    在 Telegram 里给你的机器人发一条消息，机器人会把它转给你；"
echo "    你直接回复那条消息，就能回给对方。"
echo "    管理员命令：/status /log /stop /resume /restart"
echo "               /ban /unban /banlist /who"
echo
echo "  之后如果要改 Token 或管理员 ID，编辑 ${ENV_FILE}，"
echo "  再运行 systemctl restart ${SERVICE_NAME} 即可生效。"
echo
echo "  如需卸载：systemctl disable --now ${SERVICE_NAME}，"
echo "  再删除 ${APP_DIR}、${ENV_FILE} 和 ${SERVICE_FILE}。"
echo
