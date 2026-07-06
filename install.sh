#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/chatbot"
SERVICE_NAME="chatbot.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="/etc/chatbot.env"
RAW_BASE="${CHATBOT_RAW_BASE:-https://raw.githubusercontent.com/vmenzo/chatbot/main}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash install.sh"
  exit 1
fi

read -r -s -p "请输入 Telegram Bot Token: " BOT_TOKEN
echo
read -r -p "请输入管理员 Telegram 数字 ID: " ADMIN_ID
read -r -p "管理员显示名（留空则自动识别 Telegram 名字）: " ADMIN_DISPLAY_NAME
echo "请选择 Python 部署模式："
echo "1) long polling（默认，适合普通 VPS）"
echo "2) webhook（需要公网 HTTPS 反代到本机端口）"
read -r -p "模式 [1/2，默认 1]: " MODE_CHOICE

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
    read -r -p "Webhook 监听地址 [0.0.0.0]: " WEBHOOK_LISTEN_INPUT
    read -r -p "Webhook 监听端口 [8080]: " WEBHOOK_PORT_INPUT
    read -r -p "Webhook 路径 [telegram]: " WEBHOOK_PATH_INPUT
    WEBHOOK_LISTEN="${WEBHOOK_LISTEN_INPUT:-0.0.0.0}"
    WEBHOOK_PORT="${WEBHOOK_PORT_INPUT:-8080}"
    WEBHOOK_PATH="${WEBHOOK_PATH_INPUT:-telegram}"
    WEBHOOK_PATH="${WEBHOOK_PATH#/}"
    WEBHOOK_PATH="${WEBHOOK_PATH%/}"
    if [[ -z "${WEBHOOK_PATH}" ]]; then
      echo "Webhook 路径不能为空"
      exit 1
    fi
    read -r -p "公网域名或完整 URL，例如 example.com 或 https://example.com/${WEBHOOK_PATH}: " WEBHOOK_URL_INPUT
    read -r -s -p "Webhook Secret（可留空）: " WEBHOOK_SECRET
    echo
    if [[ -z "${WEBHOOK_URL_INPUT}" ]]; then
      echo "Webhook 模式必须填写公网域名或完整 URL"
      exit 1
    fi
    WEBHOOK_URL="${WEBHOOK_URL_INPUT%/}"
    if [[ "${WEBHOOK_URL}" != http://* && "${WEBHOOK_URL}" != https://* ]]; then
      WEBHOOK_URL="https://${WEBHOOK_URL}"
    fi
    if [[ "${WEBHOOK_URL}" != */"${WEBHOOK_PATH}" ]]; then
      WEBHOOK_URL="${WEBHOOK_URL}/${WEBHOOK_PATH}"
    fi
    ;;
  *)
    echo "模式只能选择 1 或 2"
    exit 1
    ;;
esac

if [[ -z "${BOT_TOKEN}" || -z "${ADMIN_ID}" ]]; then
  echo "Token 和管理员 ID 不能为空"
  exit 1
fi

if ! [[ "${ADMIN_ID}" =~ ^[0-9]+$ ]]; then
  echo "管理员 ID 必须是数字"
  exit 1
fi

if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  if [[ -z "${WEBHOOK_URL}" ]]; then
    echo "Webhook 模式必须填写公网 HTTPS Webhook URL"
    exit 1
  fi
  if [[ "${WEBHOOK_URL}" != https://* ]]; then
    echo "Webhook URL 必须是 HTTPS 地址"
    exit 1
  fi
  if ! [[ "${WEBHOOK_PORT}" =~ ^[0-9]+$ ]]; then
    echo "Webhook 端口必须是数字"
    exit 1
  fi
fi

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

install_project_file() {
  local filename="$1"
  local source_file
  source_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/${filename}"

  if [[ -f "${source_file}" ]]; then
    cp "${source_file}" "${APP_DIR}/${filename}"
    return
  fi

  if [[ -z "${RAW_BASE}" ]]; then
    echo "找不到 ${filename}。"
    echo "如果用 GitHub 一行安装，请这样运行："
    echo "sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh)\""
    exit 1
  fi

  curl -fsSL "${RAW_BASE%/}/${filename}" -o "${APP_DIR}/${filename}"
}

apt-get update
apt-get install -y ca-certificates curl python3 python3-venv python3-pip

mkdir -p "${APP_DIR}"
echo "准备安装 Python ${CHATBOT_MODE} 模式。"
echo "安装目录：${APP_DIR}"
echo "将安装文件：chatbot.py requirements.txt"
install_project_file "chatbot.py"
install_project_file "requirements.txt"
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  echo "Webhook 模式额外安装文件：requirements-webhook.txt"
  echo "Webhook URL：${WEBHOOK_URL}"
  install_project_file "requirements-webhook.txt"
fi

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
if [[ "${CHATBOT_MODE}" == "webhook" ]]; then
  "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements-webhook.txt"
fi

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

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "安装完成。"
echo "部署模式：${CHATBOT_MODE}"
echo "查看状态：systemctl status ${SERVICE_NAME}"
echo "查看日志：journalctl -u ${SERVICE_NAME} -f"
