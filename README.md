# Telegram 双向聊天机器人

## 一行安装

直接复制下面命令安装：

```bash
curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh -o /tmp/chatbot-install.sh && sudo CHATBOT_RAW_BASE=https://raw.githubusercontent.com/vmenzo/chatbot/main bash /tmp/chatbot-install.sh
```

按提示输入：

- Telegram Bot Token
- 管理员 Telegram 数字 ID
- 管理员显示名，留空则自动识别

## 管理命令

```bash
systemctl status chatbot.service
journalctl -u chatbot.service -f
systemctl restart chatbot.service
```
