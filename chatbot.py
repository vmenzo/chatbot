import sys
import re
import json
import os
import shutil
import subprocess as sp
import time
from html import escape
from pathlib import Path
from datetime import timedelta
from typing import Optional

from telegram import Update, BotCommand, BotCommandScopeDefault, BotCommandScopeChat
from telegram.ext import (
    ApplicationBuilder, CommandHandler, MessageHandler, filters, ContextTypes
)

# ================= 配置区 =================
TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
ADMIN_ID = int(os.environ["TELEGRAM_ADMIN_ID"])
SERVICE_NAME = os.environ.get("CHATBOT_SERVICE_NAME", "chatbot.service")
DATA_DIR = Path(os.environ.get("CHATBOT_DATA_DIR", Path(__file__).resolve().parent))
BAN_FILE = DATA_DIR / "banned_users.json"
MESSAGE_MAP_FILE = DATA_DIR / "admin_message_map.json"
ADMIN_DISPLAY_NAME = os.environ.get("ADMIN_DISPLAY_NAME", "").strip()
CHATBOT_MODE = os.environ.get("CHATBOT_MODE", "polling").strip().lower()
WEBHOOK_LISTEN = os.environ.get("CHATBOT_WEBHOOK_LISTEN", "0.0.0.0")
WEBHOOK_PORT = int(os.environ.get("CHATBOT_WEBHOOK_PORT", "8080"))
WEBHOOK_PATH = os.environ.get("CHATBOT_WEBHOOK_PATH", "telegram").strip("/")
WEBHOOK_URL = os.environ.get("CHATBOT_WEBHOOK_URL", "").strip()
WEBHOOK_SECRET = os.environ.get("CHATBOT_WEBHOOK_SECRET", "").strip() or None
# ==========================================


def load_banned_users() -> set[int]:
    try:
        data = json.loads(BAN_FILE.read_text(encoding="utf-8"))
        return {int(uid) for uid in data}
    except FileNotFoundError:
        return set()
    except Exception as e:
        # 文件损坏时不要静默丢掉：把坏文件改名备份，留着以后恢复或排查
        try:
            if BAN_FILE.exists():
                stamp = time.strftime("%Y%m%d_%H%M%S")
                BAN_FILE.rename(BAN_FILE.with_name(f"{BAN_FILE.name}.corrupt-{stamp}"))
        except Exception:
            pass
        print(f"[WARN] 读取封禁列表失败（损坏文件已备份）: {e}", file=sys.stderr, flush=True)
        return set()


def save_banned_users(user_ids: set[int]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    BAN_FILE.write_text(
        json.dumps(sorted(user_ids), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def get_banned_users(context: ContextTypes.DEFAULT_TYPE) -> set[int]:
    if "banned_users" not in context.bot_data:
        context.bot_data["banned_users"] = load_banned_users()
    return context.bot_data["banned_users"]


def load_message_map() -> dict[str, int]:
    try:
        data = json.loads(MESSAGE_MAP_FILE.read_text(encoding="utf-8"))
        return {str(k): int(v) for k, v in data.items()}
    except FileNotFoundError:
        return {}
    except Exception as e:
        # 文件损坏时不要静默丢掉：把坏文件改名备份，留着以后恢复或排查
        try:
            if MESSAGE_MAP_FILE.exists():
                stamp = time.strftime("%Y%m%d_%H%M%S")
                MESSAGE_MAP_FILE.rename(MESSAGE_MAP_FILE.with_name(f"{MESSAGE_MAP_FILE.name}.corrupt-{stamp}"))
        except Exception:
            pass
        print(f"[WARN] 读取消息映射失败（损坏文件已备份）: {e}", file=sys.stderr, flush=True)
        return {}


def save_message_map(message_map: dict[str, int]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if len(message_map) > 2000:
        keep_keys = sorted(message_map.keys(), key=int)[-2000:]
        message_map = {k: message_map[k] for k in keep_keys}
    MESSAGE_MAP_FILE.write_text(
        json.dumps(message_map, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def get_message_map(context: ContextTypes.DEFAULT_TYPE) -> dict[str, int]:
    if "admin_message_map" not in context.bot_data:
        context.bot_data["admin_message_map"] = load_message_map()
    return context.bot_data["admin_message_map"]


def remember_admin_message(context: ContextTypes.DEFAULT_TYPE, message_id: int, user_id: int) -> None:
    message_map = get_message_map(context)
    message_map[str(message_id)] = user_id
    save_message_map(message_map)


def extract_target_id(message, context: Optional[ContextTypes.DEFAULT_TYPE] = None) -> Optional[int]:
    if context:
        mapped_id = get_message_map(context).get(str(message.message_id))
        if mapped_id:
            return mapped_id

    entities = message.entities or message.caption_entities or []
    for e in entities:
        if e.type == "text_mention" and e.user:
            return e.user.id
        if e.type == "text_link" and e.url and "tg://user?id=" in e.url:
            try:
                return int(e.url.rsplit("=", 1)[-1])
            except ValueError:
                return None

    text = message.text or message.caption or ""
    match = re.search(r"用户ID[：:]\s*(\d+)", text)
    if match:
        return int(match.group(1))
    return None


async def get_admin_display_name(context: ContextTypes.DEFAULT_TYPE) -> str:
    if ADMIN_DISPLAY_NAME:
        return ADMIN_DISPLAY_NAME
    if "admin_display_name" in context.bot_data:
        return context.bot_data["admin_display_name"]

    try:
        chat = await context.bot.get_chat(ADMIN_ID)
        name_parts = [chat.first_name, chat.last_name]
        name = " ".join(part for part in name_parts if part).strip()
        if not name and chat.username:
            name = f"@{chat.username}"
    except Exception as e:
        print(f"[WARN] 获取管理员名字失败: {e}", file=sys.stderr, flush=True)
        name = "管理员"

    context.bot_data["admin_display_name"] = name or "管理员"
    return context.bot_data["admin_display_name"]


# ── 用户命令 ──────────────────────────────────

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id == ADMIN_ID:
        admin_name = await get_admin_display_name(context)
        await update.message.reply_text(f"👋 {admin_name} 您好！双向回复机器人已启动，准备接收消息。")
    else:
        await update.message.reply_text("你好！请直接发送您的问题或信息，我会第一时间转达。")

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id == ADMIN_ID:
        await update.message.reply_text(
            "💡 <b>管理员使用说明</b>\n\n"
            "用户发来的消息会以卡片形式转给您，直接<b>回复那张卡片</b>就能回给对方。\n\n"
            "管理命令：\n"
            "/status 查看运行状态\n"
            "/log 查看最近日志\n"
            "/stop 暂停转发\n"
            "/resume 恢复转发\n"
            "/ban 封禁用户（回复卡片发送，或 /ban 用户ID）\n"
            "/unban 解除封禁\n"
            "/banlist 封禁列表\n"
            "/who 识别被回复消息来自哪个用户\n"
            "/restart 重启服务",
            parse_mode='HTML',
        )
        return
    await update.message.reply_text(
        "💡 <b>使用说明</b>\n\n"
        "本机器人用于与管理员直接沟通。您无需使用任何特殊格式，直接向我发送：\n"
        "• 文字消息\n"
        "• 报错截图 / 照片\n"
        "• 日志文件\n\n"
        "管理员看到后会第一时间回复您（主要活跃于北京时间白天）。",
        parse_mode='HTML',
    )

async def about_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    admin_name = await get_admin_display_name(context)
    if update.message.from_user.id == ADMIN_ID:
        await update.message.reply_text(
            f"🛠 这里是 {admin_name} 小助手（管理员版）。\n\n"
            "用户消息会转发给您，回复卡片即可回给对方。\n"
            "发送 /help 查看管理命令。"
        )
        return
    await update.message.reply_text(
        f"🛠 这里是 {admin_name} 小助手。\n\n"
        "支持与管理员双向聊天，主要处理服务器咨询、脚本交流等相关事宜。"
    )

async def ping_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("🏓 Pong! 机器人后台服务运行正常。")


# ── 管理员命令 ────────────────────────────────

def _systemd_bytes(value):
    """解析 systemctl show 的字节数值。

    记账不可用时返回 "[not set]"，systemd 249 对未设置项返回 2^64-1 哨兵值，
    这两种情况都当成未知（None），别让一个字段拖垮整个 /status。
    """
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    if n < 0 or n >= 2**63:
        return None
    return n


async def admin_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return
    try:
        r = sp.run(
            ["systemctl", "show", SERVICE_NAME,
             "-p", "MainPID", "-p", "ActiveState", "-p", "ActiveEnterTimestamp",
             "-p", "MemoryCurrent", "-p", "MemoryPeak", "-p", "CPUUsageNSec",
             "-p", "TasksCurrent", "-p", "LoadState", "-p", "UnitFileState"],
            capture_output=True, text=True, timeout=5,
        )
        raw = {}
        for line in r.stdout.strip().split("\n"):
            if "=" in line:
                k, v = line.split("=", 1)
                raw[k] = v

        pid = raw.get("MainPID", "?")
        mem_cur = _systemd_bytes(raw.get("MemoryCurrent"))
        mem_peak = _systemd_bytes(raw.get("MemoryPeak"))
        cpu_raw = _systemd_bytes(raw.get("CPUUsageNSec"))
        mem_text = f"{mem_cur // 1048576} MB" if mem_cur is not None else "未知"
        peak_text = f"{mem_peak // 1048576} MB" if mem_peak is not None else "未知"
        cpu_text = f"{round(cpu_raw / 1e9, 3)} 秒" if cpu_raw is not None else "未知"
        tasks_raw = raw.get("TasksCurrent", "?")
        tasks = tasks_raw if tasks_raw not in ("[not set]", "") else "未知"
        loaded = "已加载" if raw.get("LoadState") == "loaded" else raw.get("LoadState", "?")
        enabled = "开机自启" if raw.get("UnitFileState") == "enabled" else raw.get("UnitFileState", "?")
        active_state = raw.get("ActiveState", "?")
        state_text = "运行中" if active_state == "active" else active_state

        uptime = ""
        try:
            r2 = sp.run(["ps", "-p", pid, "-o", "etime="], capture_output=True, text=True, timeout=3)
            uptime = r2.stdout.strip()
        except Exception:
            pass

        start_ts = raw.get("ActiveEnterTimestamp", "")
        if start_ts:
            try:
                start_ts = start_ts.split(".")[0].replace("T", " ").replace("Z", " UTC")
            except Exception:
                pass

        await update.message.reply_text(
            f"<b>🤖 机器人状态</b>\n"
            f"📦 服务名：{escape(SERVICE_NAME)}\n"
            f"📋 加载：{loaded}\n"
            f"🔌 自启：{enabled}\n"
            f"🟢 状态：{escape(state_text)}\n"
            f"⏱ 运行时长：{uptime}\n"
            f"🕐 启动时间：{start_ts}\n"
            f"🆔 主进程ID：{pid}\n"
            f"🧵 任务数：{tasks}\n"
            f"💾 内存：{mem_text}（峰值 {peak_text}）\n"
            f"⚡ CPU：{cpu_text}",
            parse_mode='HTML',
        )
    except Exception as e:
        await update.message.reply_text(f"❌ 获取状态失败: {e}")

async def admin_restart(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return
    # 手动运行时没有 systemd，静默失败会让管理员以为重启成功了
    if shutil.which("systemctl") is None:
        await update.message.reply_text("❌ 当前不是 systemd 部署，无法通过 /restart 重启，请手动重启机器人。")
        return
    await update.message.reply_text("🔄 正在重启...")
    # 用 Popen 分离进程，避免自身被杀导致异常
    sp.Popen(["systemctl", "restart", SERVICE_NAME])

async def admin_log(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return
    try:
        r = sp.run(
            ["journalctl", "-u", SERVICE_NAME, "--no-pager", "-n", "10", "-o", "cat"],
            capture_output=True, text=True, timeout=5,
        )
        logs = r.stdout.strip() or "暂无日志"
        translations = [
            (r"^Started (.*?)\.$", r"已启动 \1"),
            (r"^Starting (.*?)\.\.\.$", r"正在启动 \1"),
            (r"^Stopped (.*?)\.$", r"已停止 \1"),
            (r"^Stopping (.*?)\.\.\.$", r"正在停止 \1"),
            (r": Deactivated successfully\.$", r": 已成功停用"),
            (r": Failed with result ", r": 启动失败，结果: "),
        ]
        for pat, rep in translations:
            logs = re.sub(pat, rep, logs, flags=re.MULTILINE)
        await update.message.reply_text(
            f"<b>📋 最近日志</b>\n<pre>{escape(logs[-3500:])}</pre>",
            parse_mode='HTML',
        )
    except Exception as e:
        await update.message.reply_text(f"❌ 获取日志失败: {e}")

async def admin_stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return
    context.bot_data['paused'] = True
    await update.message.reply_text("⏸️ 已暂停，不再转发用户消息。发送 /resume 恢复。")

async def admin_resume(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return
    context.bot_data['paused'] = False
    await update.message.reply_text("▶️ 已恢复，继续转发用户消息。")


async def admin_ban(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return

    target_id = None
    if update.message.reply_to_message:
        target_id = extract_target_id(update.message.reply_to_message, context)
    if not target_id and context.args:
        try:
            target_id = int(context.args[0])
        except ValueError:
            pass

    if not target_id:
        if update.message.reply_to_message:
            await update.message.reply_text("❌ 这条被回复消息里没有可识别的用户ID。请回复新的用户卡片/媒体，或发送 /ban 用户ID")
        else:
            await update.message.reply_text("用法：回复用户卡片发送 /ban，或发送 /ban 用户ID")
        return
    if target_id == ADMIN_ID:
        await update.message.reply_text("不能封禁管理员。")
        return

    banned_users = get_banned_users(context)
    banned_users.add(target_id)
    save_banned_users(banned_users)
    await update.message.reply_text(f"🚫 已封禁用户：<code>{target_id}</code>", parse_mode='HTML')


async def admin_unban(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return

    target_id = None
    if update.message.reply_to_message:
        target_id = extract_target_id(update.message.reply_to_message, context)
    if not target_id and context.args:
        try:
            target_id = int(context.args[0])
        except ValueError:
            pass

    if not target_id:
        if update.message.reply_to_message:
            await update.message.reply_text("❌ 这条被回复消息里没有可识别的用户ID。请回复新的用户卡片/媒体，或发送 /unban 用户ID")
        else:
            await update.message.reply_text("用法：回复用户卡片发送 /unban，或发送 /unban 用户ID")
        return

    banned_users = get_banned_users(context)
    banned_users.discard(target_id)
    save_banned_users(banned_users)
    await update.message.reply_text(f"✅ 已解除封禁：<code>{target_id}</code>", parse_mode='HTML')


async def admin_banlist(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return

    banned_users = sorted(get_banned_users(context))
    if not banned_users:
        await update.message.reply_text("封禁列表为空。")
        return

    body = "\n".join(f"<code>{uid}</code>" for uid in banned_users[-100:])
    await update.message.reply_text(
        f"<b>🚫 封禁列表</b>（共 {len(banned_users)} 个）\n{body}",
        parse_mode='HTML',
    )


async def admin_who(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        return

    if not update.message.reply_to_message:
        await update.message.reply_text("用法：回复用户卡片或媒体消息发送 /who")
        return

    reply_to = update.message.reply_to_message
    target_id = extract_target_id(reply_to, context)
    if target_id:
        await update.message.reply_text(f"识别到用户ID：<code>{target_id}</code>", parse_mode='HTML')
        return

    preview = (reply_to.text or reply_to.caption or "").strip()
    if len(preview) > 500:
        preview = preview[:500] + "..."
    await update.message.reply_text(
        "❌ 没有从这条被回复消息里识别到用户ID。\n"
        f"消息ID：<code>{reply_to.message_id}</code>\n"
        f"文本预览：<pre>{escape(preview or '无文本')}</pre>",
        parse_mode='HTML',
    )


# ── 消息处理 ──────────────────────────────────

async def handle_user_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """转发用户消息给管理员"""
    user = update.message.from_user

    # 管理员自己发的非回复消息忽略
    if user.id == ADMIN_ID and not update.message.reply_to_message:
        return

    # 暂停模式
    if context.bot_data.get('paused'):
        return

    if user.id in get_banned_users(context):
        return

    first_name = escape(user.first_name)
    username_text = f"(@{escape(user.username)})" if user.username else ""
    beijing_time = update.message.date + timedelta(hours=8)
    msg_time = beijing_time.strftime('%Y-%m-%d %H:%M:%S')

    # 卡片：名字（可点击链接）+ 时间；不显示用户 ID，
    # 回复找人靠消息 ID 映射表，不靠卡片里的文字。
    admin_text = (
        f"<b><a href='tg://user?id={user.id}'>{first_name}</a></b> {username_text}\n"
        f"<code>{msg_time}</code>"
    )

    if update.message.text or update.message.caption:
        content = update.message.text or update.message.caption
        admin_text += f"\n{escape(content)}"

    try:
        admin_card = await context.bot.send_message(chat_id=ADMIN_ID, text=admin_text, parse_mode='HTML')
    except Exception as e:
        # 发送失败不要直接丢掉消息：记日志，并尽量通知管理员转发失败。
        #（与 Worker 版发送后检查 .ok 的做法对等。）
        print(f"[WARN] 转发给管理员失败（用户 {user.id}）: {e}", file=sys.stderr, flush=True)
        try:
            await context.bot.send_message(
                chat_id=ADMIN_ID,
                text=f"⚠️ 收到用户 {user.id} 的消息，但转发失败：{e}",
            )
        except Exception:
            pass
        return
    remember_admin_message(context, admin_card.message_id, user.id)

    # 媒体消息：卡片下发原文件
    if not update.message.text:
        try:
            copied = await context.bot.copy_message(
                chat_id=ADMIN_ID,
                from_chat_id=user.id,
                message_id=update.message.message_id,
            )
        except Exception as e:
            print(f"[WARN] 转发媒体给管理员失败（用户 {user.id}）: {e}", file=sys.stderr, flush=True)
            try:
                await context.bot.send_message(
                    chat_id=ADMIN_ID,
                    text=f"⚠️ 用户 {user.id} 的媒体消息转发失败：{e}",
                )
            except Exception:
                pass
            return
        remember_admin_message(context, copied.message_id, user.id)


async def handle_admin_reply(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """管理员回复 → 无痕转发给原用户"""
    if update.message.from_user.id != ADMIN_ID:
        return

    reply_to = update.message.reply_to_message
    if not reply_to:
        return

    # 只有回复 bot 自己发的消息才转发
    if reply_to.from_user.id != context.bot.id:
        return

    target_id = extract_target_id(reply_to, context)

    if not target_id:
        await update.message.reply_text("❌ 找不到目标用户ID，请回复机器人转发的用户卡片或媒体消息。")
        return

    if target_id in get_banned_users(context):
        await update.message.reply_text("🚫 该用户已被封禁，未发送。")
        return

    try:
        await context.bot.copy_message(
            chat_id=target_id,
            from_chat_id=ADMIN_ID,
            message_id=update.message.message_id,
        )
    except Exception as e:
        await update.message.reply_text(f"❌ 发送失败: {e}")


# ── 全局错误处理 ──────────────────────────────

async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE):
    """捕获未处理的异常，通知管理员"""
    import traceback
    tb = ''.join(traceback.format_exception(context.error))
    print(f"[ERROR] {tb}", file=sys.stderr, flush=True)
    if update and hasattr(update, 'effective_chat'):
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=f"⚠️ <b>Bot 异常</b>\n<pre>{escape(tb[-1500:])}</pre>",
            parse_mode='HTML',
        )


# ── 入口 ──────────────────────────────────────

def build_application():
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_error_handler(error_handler)

    # 用户命令
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_command))
    app.add_handler(CommandHandler("about", about_command))
    app.add_handler(CommandHandler("ping", ping_command))
    # 管理员命令
    app.add_handler(CommandHandler("status", admin_status))
    app.add_handler(CommandHandler("restart", admin_restart))
    app.add_handler(CommandHandler("log", admin_log))
    app.add_handler(CommandHandler("stop", admin_stop))
    app.add_handler(CommandHandler("resume", admin_resume))
    app.add_handler(CommandHandler("ban", admin_ban))
    app.add_handler(CommandHandler("unban", admin_unban))
    app.add_handler(CommandHandler("banlist", admin_banlist))
    app.add_handler(CommandHandler("who", admin_who))
    # 消息处理（顺序重要：回复优先匹配）
    app.add_handler(MessageHandler(filters.REPLY & filters.User(ADMIN_ID), handle_admin_reply))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, handle_user_message))

    # 启动时注册命令菜单
    async def post_init(app):
        user_cmds = [
            BotCommand("start", "开始使用"),
            BotCommand("help", "使用说明"),
            BotCommand("about", "关于"),
            BotCommand("ping", "检查在线"),
        ]
        admin_cmds = user_cmds + [
            BotCommand("status", "运行状态"),
            BotCommand("log", "最近日志"),
            BotCommand("stop", "暂停转发"),
            BotCommand("resume", "恢复转发"),
            BotCommand("ban", "封禁用户"),
            BotCommand("unban", "解除封禁"),
            BotCommand("banlist", "封禁列表"),
            BotCommand("who", "识别用户ID"),
            BotCommand("restart", "重启服务"),
        ]
        await app.bot.set_my_commands(user_cmds, scope=BotCommandScopeDefault())
        await app.bot.set_my_commands(admin_cmds, scope=BotCommandScopeChat(chat_id=ADMIN_ID))

    app.post_init = post_init

    return app


if __name__ == '__main__':
    app = build_application()

    if CHATBOT_MODE == "polling":
        print("机器人已启动：long polling 模式", file=sys.stderr, flush=True)
        app.run_polling()
    elif CHATBOT_MODE == "webhook":
        if not WEBHOOK_URL:
            raise RuntimeError("CHATBOT_MODE=webhook 时必须设置 CHATBOT_WEBHOOK_URL")
        print(
            f"机器人已启动：webhook 模式，监听 {WEBHOOK_LISTEN}:{WEBHOOK_PORT}/{WEBHOOK_PATH}",
            file=sys.stderr,
            flush=True,
        )
        app.run_webhook(
            listen=WEBHOOK_LISTEN,
            port=WEBHOOK_PORT,
            url_path=WEBHOOK_PATH,
            webhook_url=WEBHOOK_URL,
            secret_token=WEBHOOK_SECRET,
        )
    else:
        raise RuntimeError("CHATBOT_MODE 只能是 polling 或 webhook")
