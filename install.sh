#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/chatbot"
SERVICE_NAME="chatbot.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="/etc/chatbot.env"
RAW_BASE="${CHATBOT_RAW_BASE:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash install.sh"
  exit 1
fi

read -r -p "请输入 Telegram Bot Token: " BOT_TOKEN
read -r -p "请输入管理员 Telegram 数字 ID: " ADMIN_ID
read -r -p "管理员显示名（留空则自动识别 Telegram 名字）: " ADMIN_DISPLAY_NAME

if [[ -z "${BOT_TOKEN}" || -z "${ADMIN_ID}" ]]; then
  echo "Token 和管理员 ID 不能为空"
  exit 1
fi

if ! [[ "${ADMIN_ID}" =~ ^[0-9]+$ ]]; then
  echo "管理员 ID 必须是数字"
  exit 1
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
    echo "curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/install.sh -o /tmp/chatbot-install.sh && sudo CHATBOT_RAW_BASE=https://raw.githubusercontent.com/你的用户名/你的仓库/main bash /tmp/chatbot-install.sh"
    exit 1
  fi

  curl -fsSL "${RAW_BASE%/}/${filename}" -o "${APP_DIR}/${filename}"
}

apt-get update
apt-get install -y ca-certificates curl python3 python3-venv python3-pip

mkdir -p "${APP_DIR}"
install_project_file "chatbot.py"
install_project_file "requirements.txt"

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

cat > "${ENV_FILE}" <<EOF
TELEGRAM_BOT_TOKEN=$(escape_env_value "${BOT_TOKEN}")
TELEGRAM_ADMIN_ID=${ADMIN_ID}
CHATBOT_SERVICE_NAME=$(escape_env_value "${SERVICE_NAME}")
CHATBOT_DATA_DIR=$(escape_env_value "${APP_DIR}")
ADMIN_DISPLAY_NAME=$(escape_env_value "${ADMIN_DISPLAY_NAME}")
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
echo "查看状态：systemctl status ${SERVICE_NAME}"
echo "查看日志：journalctl -u ${SERVICE_NAME} -f"
