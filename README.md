# Telegram 双向聊天机器人

## 一行安装

把仓库上传到 GitHub 后，把下面命令里的 `你的用户名/你的仓库` 改成真实仓库地址：

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/install.sh -o /tmp/chatbot-install.sh && sudo CHATBOT_RAW_BASE=https://raw.githubusercontent.com/你的用户名/你的仓库/main bash /tmp/chatbot-install.sh
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
