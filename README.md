# Telegram 双向聊天机器人

支持三种部署方式：

- Python long polling：默认方式，适合 VPS/systemd 常驻运行
- Python webhook：适合有公网 HTTPS 入口的服务器
- Cloudflare Workers webhook：适合无服务器部署，状态保存到 Cloudflare KV

## 一行安装

直接复制下面命令安装：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh)"
```

按提示输入：

- Telegram Bot Token
- 管理员 Telegram 数字 ID
- 管理员显示名，留空则自动识别
- Python 部署模式：long polling 或 webhook

安装脚本会在开始安装前明确显示本次模式、安装目录和会下载的文件。

## 管理命令

```bash
systemctl status chatbot.service
journalctl -u chatbot.service -f
systemctl restart chatbot.service
```

## Python 运行模式

一行安装脚本会按你的选择写入 systemd 环境变量。默认是 long polling：

```bash
CHATBOT_MODE=polling python chatbot.py
```

如果要用 Python webhook，需要提供公网 HTTPS webhook 地址：

```bash
CHATBOT_MODE=webhook \
CHATBOT_WEBHOOK_LISTEN=0.0.0.0 \
CHATBOT_WEBHOOK_PORT=8080 \
CHATBOT_WEBHOOK_PATH=telegram \
CHATBOT_WEBHOOK_URL=https://你的域名/telegram \
CHATBOT_WEBHOOK_SECRET=自定义密钥 \
python chatbot.py
```

一行安装选择 webhook 时，可以在 URL 那一步只填域名，例如：

```text
Webhook 路径 [telegram]: telegram
公网域名或完整 URL，例如 example.com 或 https://example.com/telegram: example.com
```

脚本会自动补成：

```text
https://example.com/telegram
```

Python webhook 版本仍然保留 `/status`、`/log`、`/restart` 等 systemd 管理命令。

一行安装会按选择下载 Python 运行必需文件：

- long polling：只下载 `chatbot.py` 和 `requirements.txt`
- webhook：下载 `chatbot.py`、`requirements.txt` 和 `requirements-webhook.txt`

一行安装不会下载 Cloudflare Workers 目录。

## Cloudflare Workers 部署

Worker 版本在 `worker/` 目录，使用 Telegram webhook，不依赖 Python 或 systemd。

推荐使用交互式部署脚本：

```bash
cd worker
bash deploy.sh
```

脚本会提示输入：

- Cloudflare Worker 名称
- Telegram Bot Token
- 管理员 Telegram 数字 ID
- 管理员显示名
- Webhook Secret，留空则自动生成
- Worker 域名，留空则尝试使用 workers.dev 部署地址

Bot Token 会写入 Cloudflare Worker Secret，不会保存到 `wrangler.toml` 或仓库文件里。

脚本会自动执行完整部署流程：

- 安装 Worker 依赖
- 检查或引导 `wrangler login`
- 查找或创建 KV namespace
- 生成 `wrangler.toml`
- 写入 Worker secrets
- 部署 Worker
- 调用 Telegram `setWebhook`
- 同步 Telegram 命令菜单

也可以手动部署，但需要你自己补齐 Telegram 命令菜单同步；推荐直接用 `bash deploy.sh`。

先创建 KV：

```bash
cd worker
npx wrangler kv namespace create CHATBOT_KV
cp wrangler.example.toml wrangler.toml
```

把命令输出的 KV namespace id 填到 `wrangler.toml`。

设置密钥：

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
npx wrangler secret put TELEGRAM_ADMIN_ID
npx wrangler secret put ADMIN_DISPLAY_NAME
npx wrangler secret put WEBHOOK_SECRET
```

部署：

```bash
npx wrangler deploy
```

部署后设置 Telegram webhook，`WEBHOOK_SECRET` 既作为 Telegram secret token，也可以放在路径末尾：

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -d "url=https://你的-worker域名/${WEBHOOK_SECRET}" \
  -d "secret_token=${WEBHOOK_SECRET}"
```

Worker 版本支持用户转发、管理员回复、`/ban`、`/unban`、`/banlist`、`/who`、`/stop`、`/resume`、`/ping`、`/status`。其中 `/log` 和 `/restart` 不支持 systemd 行为，需要在 Cloudflare 控制台查看日志或重新部署。
