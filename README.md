# Telegram 双向聊天机器人

一个 Telegram Bot，让用户和管理员直接对话：用户给 Bot 发消息，Bot 转给管理员；管理员直接回复，就能回给用户。不用加好友，不用建群。

## 它能做什么

- **双向转发**：用户发来的文字、图片、文件，原样转给管理员；管理员回复那条消息，就原样转回给用户。
- **封禁管理**：`/ban` 封禁骚扰用户，`/unban` 解封，`/banlist` 查看封禁列表，`/who` 识别消息来自哪个用户。
- **暂停与恢复**：`/stop` 暂停转发，`/resume` 恢复。
- **运行状态**：`/status` 查看运行状态，`/log` 查看最近日志，`/restart` 重启服务（仅 Python 版）。

## 收发是什么样的

用户发消息后，管理员会收到一张卡片：

- 第一行是用户的名字（可以点进对方资料）和 @用户名
- 第二行是北京时间
- 下面是消息内容；图片、文件会原样跟在下面

管理员直接**回复这张卡片**就能回给用户，不用记用户 ID，也不用输任何命令。Python 版和 Workers 版的对话框是一样的。

## 三种部署方式怎么选

| 方式 | 适合谁 | 需要什么 |
| --- | --- | --- |
| Python long polling（默认） | 有一台 VPS，想省事 | Debian / Ubuntu 服务器、root 权限 |
| Python webhook | 有公网 HTTPS 入口的服务器 | 域名、HTTPS |
| Cloudflare Workers | 不想养服务器 | Cloudflare 账号（免费版即可）、Node.js |

三种方式跑的是同一个机器人，功能基本一致。**同一个 Bot 同一时间只能用一种方式**：polling 和 webhook 会冲突，换方式之前要先停掉正在跑的那一边。

开始之前，请先准备好下面两样东西：

1. **Telegram Bot Token**：在 Telegram 里找 `@BotFather`，发送 `/newbot` 按提示创建一个机器人，创建成功后会得到一串 Token，形如 `123456789:AAE...`。
2. **管理员 Telegram 数字 ID**：在 Telegram 里找 `@userinfobot`，随便发一条消息，它会回复你的数字 ID。注意：要的是纯数字 ID，不是 `@用户名`。

---

## 方式一：Python 一行安装（VPS，推荐）

### 要求

- Debian 11+ / Ubuntu 22.04+（需要 Python 3.9+）
- 带 systemd 的系统
- root 权限

### 安装

直接复制下面命令安装（先下载到临时文件，下载成功才执行；直接用 `bash -c "$(curl ...)"` 的写法下载失败时会静默退出、退出码还是 0，看起来像装完了，实际什么都没装）：

```bash
curl -fsSL https://raw.githubusercontent.com/vmenzo/chatbot/main/install.sh -o /tmp/chatbot-install.sh && sudo bash /tmp/chatbot-install.sh
```

安装脚本分 8 步走完，全程有中文提示：

1. 检查运行环境（root 权限、systemd）
2. 收集配置（下面这几项）
3. 安装前确认（先给你看一张汇总表，确认了才动手）
4. 安装系统依赖（Python 3、curl 等）
5. 下载程序文件
6. 创建 Python 虚拟环境并安装依赖
7. 写入配置文件
8. 注册 systemd 服务并启动，启动后会检查服务是不是真的起来了

安装时会问你：

- Telegram Bot Token（输入时不回显；格式不对会提醒你重贴）
- 管理员 Telegram 数字 ID（只接受纯数字，输错了可以重输）
- 管理员显示名（可选，留空则自动识别你的 Telegram 名字）
- 部署模式：`1` long polling（默认，不用域名最省事）或 `2` webhook（需要公网 HTTPS）

选 webhook 时还会问：本机监听地址（默认 `0.0.0.0`）、监听端口（默认 `8080`）、Webhook 路径（默认 `telegram`）、公网域名或完整 URL、Webhook Secret（可选）。

只填域名也可以，脚本会自动补成完整地址，例如：

```text
Webhook 路径 [默认 telegram]: （直接回车）
请输入公网域名或完整 URL: example.com
```

自动补成：

```text
https://example.com/telegram
```

按部署模式的不同，安装脚本会下载不同的文件：

- long polling：只下载 `chatbot.py` 和 `requirements.txt`
- webhook：下载 `chatbot.py`、`requirements.txt` 和 `requirements-webhook.txt`

一行安装不会下载 Cloudflare Workers 目录（`worker/`）。

### 装完之后

```bash
# 查看运行状态
systemctl status chatbot.service

# 实时查看日志
journalctl -u chatbot.service -f

# 重启机器人
systemctl restart chatbot.service

# 停止机器人
systemctl stop chatbot.service
```

### 改配置、卸载

- 改 Token 或管理员 ID：编辑 `/etc/chatbot.env`，再运行 `systemctl restart chatbot.service` 即可生效。
- 卸载：先停掉服务，再删掉相关文件：

```bash
systemctl disable --now chatbot.service
rm -rf /opt/chatbot /etc/chatbot.env /etc/systemd/system/chatbot.service
systemctl daemon-reload
```

---

## 方式二：Python 手动运行（不用安装脚本）

如果你不想用安装脚本，也可以自己准备环境变量后直接运行。先装依赖（建议先建虚拟环境，`python3 -m venv venv` 再 `source venv/bin/activate`）：

```bash
pip install -r requirements.txt
```

webhook 模式还要多装一个：

```bash
pip install -r requirements-webhook.txt
```

不装依赖直接跑会报 `ModuleNotFoundError: No module named 'telegram'`。

需要的环境变量（也可以参考仓库里的 `.env.example`）：

| 环境变量 | 说明 | 默认值 |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | Bot Token（必填） | — |
| `TELEGRAM_ADMIN_ID` | 管理员数字 ID（必填） | — |
| `ADMIN_DISPLAY_NAME` | 管理员显示名（可选） | 自动识别 |
| `CHATBOT_SERVICE_NAME` | systemd 服务名（可选） | `chatbot.service` |
| `CHATBOT_DATA_DIR` | 数据存放目录（可选） | 程序所在目录 |
| `CHATBOT_MODE` | `polling` 或 `webhook`（可选） | `polling` |
| `CHATBOT_WEBHOOK_LISTEN` | webhook 本机监听地址 | `0.0.0.0` |
| `CHATBOT_WEBHOOK_PORT` | webhook 本机监听端口 | `8080` |
| `CHATBOT_WEBHOOK_PATH` | webhook 路径 | `telegram` |
| `CHATBOT_WEBHOOK_URL` | 公网 webhook 地址（webhook 模式必填） | — |
| `CHATBOT_WEBHOOK_SECRET` | webhook 校验密钥（可选） | — |

默认 long polling，直接运行：

```bash
CHATBOT_MODE=polling python chatbot.py
```

用 Python webhook，需要提供公网 HTTPS 地址：

```bash
CHATBOT_MODE=webhook \
CHATBOT_WEBHOOK_LISTEN=0.0.0.0 \
CHATBOT_WEBHOOK_PORT=8080 \
CHATBOT_WEBHOOK_PATH=telegram \
CHATBOT_WEBHOOK_URL=https://你的域名/telegram \
CHATBOT_WEBHOOK_SECRET=自定义密钥 \
python chatbot.py
```

封禁列表和消息映射保存在数据目录的 `banned_users.json` 和 `admin_message_map.json` 里。

---

## 方式三：Cloudflare Workers 部署（无服务器）

Worker 版本在 `worker/` 目录，使用 Telegram webhook，不依赖 Python 或 systemd，状态（封禁列表、消息映射、暂停状态）保存到 Cloudflare KV。

### 要求

- Node.js 18+ 和 npm（本地电脑上用，部署完就不需要了）
- 一个 Cloudflare 账号（免费版即可，没有先去 <https://dash.cloudflare.com/sign-up> 注册）

### 一键部署（推荐）

```bash
cd worker
bash deploy.sh
```

如果本地还没有仓库代码，先用下面这一条命令拉下来、进目录、部署一次做完：

```bash
git clone https://github.com/vmenzo/chatbot.git && cd chatbot/worker && bash deploy.sh
```

没有 git 也可以去仓库页面下载 ZIP，解压后进 `worker` 目录跑 `bash deploy.sh`。

部署脚本分 9 步走完，全程有中文提示：

1. 检查运行环境（Node.js、npm、curl）
2. 收集配置（下面这几项）
3. 部署前确认（先给你看一张汇总表，确认了才动手）
4. 安装依赖（Wrangler，Cloudflare 官方命令行工具）
5. 登录 Cloudflare（第一次需要浏览器授权；在没有浏览器的服务器上运行时，把打印出的登录链接复制到自己的浏览器里打开）
6. 查找或创建 KV namespace，生成 `wrangler.toml`
7. 写入 Worker secrets
8. 部署 Worker 到 Cloudflare
9. 设置 Telegram webhook 并同步命令菜单

部署时会问你：

- Cloudflare Worker 名称（默认 `telegram-chatbot`，只能用小写字母、数字和连字符）
- Telegram Bot Token（输入时不回显；格式不对会提醒你重贴）
- 管理员 Telegram 数字 ID（只接受纯数字）
- 管理员显示名（可选，留空则使用“管理员”）
- Webhook Secret（可选，留空则自动生成）
- Worker 域名（可选）

关于域名：

- 留空则使用 Cloudflare 分配的 workers.dev 地址，例如 `telegram-chatbot.你的名字.workers.dev`，部署后自动识别。
- 如果填自己的域名（例如 `bot.example.com`），该域名必须已经托管在 Cloudflare 上（DNS 在 Cloudflare），脚本会把它绑定到 Worker。

Bot Token 会以加密的 secret 形式保存在 Cloudflare，不会保存到 `wrangler.toml` 或仓库文件里。

部署完成后，机器人运行在 Cloudflare 的服务器上，**本地电脑可以关机**，不影响运行。但请保留 `worker/` 目录（代码和 `wrangler.toml`），以后改代码、改配置，重新跑一次 `bash deploy.sh` 即可重新部署。

### 部署之后

```bash
# 实时查看日志（在 worker 目录下运行）
npx wrangler tail

# 重新部署（改代码、改配置后都用它）
bash deploy.sh

# 删除 Worker
npx wrangler delete --name telegram-chatbot
```

### 手动部署

也可以不用部署脚本，自己一步一步来（但命令菜单同步要自己补，推荐直接用 `bash deploy.sh`）。

先创建 KV：

```bash
cd worker
npx wrangler kv namespace create CHATBOT_KV
cp wrangler.example.toml wrangler.toml
```

把命令输出的 KV namespace id 填到 `wrangler.toml` 里。

设置密钥（每条都会提示你输入对应的值）：

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

部署后设置 Telegram webhook。`WEBHOOK_SECRET` 既作为 Telegram secret token，也可以放在路径末尾：

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -d "url=https://你的-worker域名/${WEBHOOK_SECRET}" \
  -d "secret_token=${WEBHOOK_SECRET}"
```

---

## 命令菜单

### 用户命令（三种方式都有）

| 命令 | 作用 |
| --- | --- |
| `/start` | 开始使用 |
| `/help` | 使用说明 |
| `/about` | 关于 |
| `/ping` | 检查机器人是否在线 |

### 管理员命令

| 命令 | 作用 | Workers 版 |
| --- | --- | --- |
| `/status` | 运行状态 | 支持 |
| `/log` | 最近日志 | 不支持（没有 systemd，去 Cloudflare 控制台看日志） |
| `/stop` | 暂停转发 | 支持 |
| `/resume` | 恢复转发 | 支持 |
| `/ban` | 封禁用户（回复用户卡片发送，或 `/ban 用户ID`） | 支持 |
| `/unban` | 解除封禁 | 支持 |
| `/banlist` | 封禁列表 | 支持 |
| `/who` | 识别被回复消息来自哪个用户 | 支持 |
| `/restart` | 重启服务 | 不支持（重新部署即可） |

---

## 常见问题

**收不到用户消息了怎么办？**

- Python 版：先看服务在不在跑：`systemctl status chatbot.service`，再看日志：`journalctl -u chatbot.service -f`。
- Workers 版：看 Cloudflare 控制台的日志，或本地跑 `npx wrangler tail`。也可以检查 webhook 是否还在：

```bash
curl "https://api.telegram.org/bot<你的Token>/getWebhookInfo"
```

**换了部署方式，机器人没反应？**

同一个 Bot 同一时间只能用一种方式。如果之前是 polling，改成 webhook 后要停掉原来跑着的 Python 服务；如果之前是 webhook，改回 polling 之前要先删掉 webhook（部署 Workers 时设的 webhook 会一直留着，polling 收不到消息）。

**换 Token 或管理员 ID 怎么办？**

- Python 版：改 `/etc/chatbot.env`，再 `systemctl restart chatbot.service`。
- Workers 版：重新跑一次 `bash deploy.sh`，或单独改一项：`npx wrangler secret put TELEGRAM_BOT_TOKEN`。

**换 Webhook Secret 怎么办？**

Secret 既放在 webhook 地址的路径末尾，也作为 `secret_token` 传给 Telegram，轮换时两处要一起换。最省事是重新跑一次 `bash deploy.sh`，Secret 那一步留空就会自动生成新的并同步好；不要只改一处。

**管理员回复没有转给用户？**

请回复机器人转发的那张卡片（或媒体消息），不要直接发新消息。直接发的新消息机器人不知道要转给谁，会忽略。

---

## 目录结构

```text
chatbot.py                Python 版主程序
install.sh                Python 版一键安装脚本
requirements.txt          Python 版依赖
requirements-webhook.txt  Python webhook 版额外依赖
.env.example              Python 版配置模板
worker/
  deploy.sh               Workers 版一键部署脚本
  src/index.js            Workers 版主程序
  package.json            Workers 版依赖（Wrangler）
  wrangler.example.toml   wrangler.toml 模板
```
