const MAP_TTL_SECONDS = 60 * 60 * 24 * 30;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET") {
      return json({ ok: true, service: "telegram-chatbot-worker" });
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    if (env.WEBHOOK_SECRET) {
      const headerSecret = request.headers.get("x-telegram-bot-api-secret-token");
      const pathSecret = url.pathname.split("/").filter(Boolean).at(-1);
      if (headerSecret !== env.WEBHOOK_SECRET && pathSecret !== env.WEBHOOK_SECRET) {
        return new Response("Unauthorized", { status: 401 });
      }
    }

    const update = await request.json();
    await handleUpdate(update, env);
    return json({ ok: true });
  },
};

async function handleUpdate(update, env) {
  if (!update.message) return;
  const message = update.message;
  const user = message.from;
  if (!user) return;

  const adminId = Number(env.TELEGRAM_ADMIN_ID);
  const command = getCommand(message);

  if (command) {
    if (user.id === adminId) {
      await handleAdminCommand(command, message, env);
    } else {
      await handleUserCommand(command, message, env);
    }
    return;
  }

  if (user.id === adminId && message.reply_to_message) {
    await handleAdminReply(message, env);
    return;
  }

  await handleUserMessage(message, env);
}

async function handleUserCommand(command, message, env) {
  if (command.name === "start") {
    await sendMessage(env, message.chat.id, "你好！请直接发送您的问题或信息，我会第一时间转达。");
    return;
  }
  if (command.name === "help") {
    await sendMessage(
      env,
      message.chat.id,
      "💡 <b>使用说明</b>\n\n本机器人用于与管理员直接沟通。您无需使用任何特殊格式，直接向我发送：\n• 文字消息\n• 报错截图 / 照片\n• 日志文件\n\n管理员看到后会第一时间回复您（主要活跃于北京时间白天）。",
    );
    return;
  }
  if (command.name === "about") {
    const adminName = env.ADMIN_DISPLAY_NAME || "管理员";
    await sendMessage(env, message.chat.id, `🛠 这里是 ${escapeHtml(adminName)} 小助手。\n\n支持与管理员双向聊天，主要处理服务器咨询、脚本交流等相关事宜。`);
    return;
  }
  if (command.name === "ping") {
    await sendMessage(env, message.chat.id, "🏓 Pong! Worker webhook 运行正常。");
  }
}

async function handleAdminCommand(command, message, env) {
  if (command.name === "start") {
    const adminName = env.ADMIN_DISPLAY_NAME || "管理员";
    await sendMessage(env, message.chat.id, `👋 ${escapeHtml(adminName)} 您好！双向回复机器人已启动，准备接收消息。`);
    return;
  }
  if (command.name === "help") {
    await sendMessage(env, message.chat.id, "管理员可直接回复用户卡片或媒体消息完成转发，也可以使用 /ban、/unban、/banlist、/who、/stop、/resume、/status 管理机器人。");
    return;
  }
  if (command.name === "about") {
    const adminName = env.ADMIN_DISPLAY_NAME || "管理员";
    await sendMessage(env, message.chat.id, `${escapeHtml(adminName)} 双向机器人。`);
    return;
  }
  if (command.name === "ping") {
    await sendMessage(env, message.chat.id, "🏓 Pong! Worker webhook 运行正常。");
    return;
  }
  if (command.name === "status") {
    const paused = await getJson(env, "paused", false);
    const bannedUsers = await getBannedUsers(env);
    await sendMessage(
      env,
      message.chat.id,
      `<b>🤖 Worker 状态</b>\n运行模式：Cloudflare Workers webhook\n暂停转发：${paused ? "是" : "否"}\n封禁用户：${bannedUsers.length} 个`,
    );
    return;
  }
  if (command.name === "log" || command.name === "restart") {
    await sendMessage(env, message.chat.id, "Cloudflare Workers 版本不支持 systemd 日志或重启命令，请在 Cloudflare 控制台查看部署与日志。");
    return;
  }
  if (command.name === "stop") {
    await env.CHATBOT_KV.put("paused", "true");
    await sendMessage(env, message.chat.id, "⏸️ 已暂停，不再转发用户消息。发送 /resume 恢复。");
    return;
  }
  if (command.name === "resume") {
    await env.CHATBOT_KV.put("paused", "false");
    await sendMessage(env, message.chat.id, "▶️ 已恢复，继续转发用户消息。");
    return;
  }
  if (command.name === "ban" || command.name === "unban") {
    await updateBan(command.name === "ban", command.args, message, env);
    return;
  }
  if (command.name === "banlist") {
    const bannedUsers = await getBannedUsers(env);
    if (!bannedUsers.length) {
      await sendMessage(env, message.chat.id, "封禁列表为空。");
      return;
    }
    const body = bannedUsers.slice(-100).map((id) => `<code>${id}</code>`).join("\n");
    await sendMessage(env, message.chat.id, `<b>🚫 封禁列表</b>（共 ${bannedUsers.length} 个）\n${body}`);
    return;
  }
  if (command.name === "who") {
    const targetId = await extractTargetId(message.reply_to_message, env);
    await sendMessage(env, message.chat.id, targetId ? `识别到用户ID：<code>${targetId}</code>` : "❌ 没有从这条被回复消息里识别到用户ID。");
  }
}

async function handleUserMessage(message, env) {
  const adminId = Number(env.TELEGRAM_ADMIN_ID);
  if (await getJson(env, "paused", false)) return;
  if ((await getBannedUsers(env)).includes(message.from.id)) return;

  const displayName = `${escapeHtml(message.from.first_name || "")}${message.from.username ? ` (@${escapeHtml(message.from.username)})` : ""}`.trim();
  const msgTime = new Date((message.date + 8 * 60 * 60) * 1000).toISOString().slice(0, 19).replace("T", " ");
  let adminText = `<blockquote>用户：${displayName}\n用户ID：${message.from.id}\n时间：${msgTime}</blockquote>`;
  const content = message.text || message.caption;
  if (content) adminText += `\n${escapeHtml(content)}`;

  const card = await sendMessage(env, adminId, adminText);
  await rememberAdminMessage(env, card.result.message_id, message.from.id);

  if (!message.text) {
    const copied = await copyMessage(env, adminId, message.chat.id, message.message_id);
    await rememberAdminMessage(env, copied.result.message_id, message.from.id);
  }
}

async function handleAdminReply(message, env) {
  const targetId = await extractTargetId(message.reply_to_message, env);
  if (!targetId) {
    await sendMessage(env, message.chat.id, "❌ 找不到目标用户ID，请回复机器人转发的用户卡片或媒体消息。");
    return;
  }
  if ((await getBannedUsers(env)).includes(targetId)) {
    await sendMessage(env, message.chat.id, "🚫 该用户已被封禁，未发送。");
    return;
  }
  const result = await copyMessage(env, targetId, message.chat.id, message.message_id);
  if (!result.ok) {
    await sendMessage(env, message.chat.id, `❌ 发送失败: ${escapeHtml(result.description || "unknown error")}`);
  }
}

async function updateBan(shouldBan, args, message, env) {
  const adminId = Number(env.TELEGRAM_ADMIN_ID);
  let targetId = await extractTargetId(message.reply_to_message, env);
  if (!targetId && args[0] && /^\d+$/.test(args[0])) targetId = Number(args[0]);

  if (!targetId) {
    await sendMessage(env, message.chat.id, `用法：回复用户卡片发送 /${shouldBan ? "ban" : "unban"}，或发送 /${shouldBan ? "ban" : "unban"} 用户ID`);
    return;
  }
  if (shouldBan && targetId === adminId) {
    await sendMessage(env, message.chat.id, "不能封禁管理员。");
    return;
  }

  const users = new Set(await getBannedUsers(env));
  if (shouldBan) users.add(targetId);
  else users.delete(targetId);
  await env.CHATBOT_KV.put("banned_users", JSON.stringify([...users].sort((a, b) => a - b)));
  await sendMessage(env, message.chat.id, shouldBan ? `🚫 已封禁用户：<code>${targetId}</code>` : `✅ 已解除封禁：<code>${targetId}</code>`);
}

async function extractTargetId(message, env) {
  if (!message) return null;
  const mapped = await env.CHATBOT_KV.get(`map:${message.message_id}`);
  if (mapped) return Number(mapped);

  const entities = message.entities || message.caption_entities || [];
  for (const entity of entities) {
    if (entity.type === "text_mention" && entity.user) return entity.user.id;
    if (entity.type === "text_link" && entity.url && entity.url.includes("tg://user?id=")) {
      const id = Number(entity.url.split("=").at(-1));
      if (Number.isFinite(id)) return id;
    }
  }

  const text = message.text || message.caption || "";
  const match = text.match(/用户ID[：:]\s*(\d+)/);
  return match ? Number(match[1]) : null;
}

function getCommand(message) {
  const text = message.text || message.caption || "";
  if (!text.startsWith("/")) return null;
  const [rawName, ...args] = text.trim().split(/\s+/);
  const name = rawName.slice(1).split("@")[0].toLowerCase();
  return { name, args };
}

async function rememberAdminMessage(env, messageId, userId) {
  await env.CHATBOT_KV.put(`map:${messageId}`, String(userId), { expirationTtl: MAP_TTL_SECONDS });
}

async function getBannedUsers(env) {
  return getJson(env, "banned_users", []);
}

async function getJson(env, key, fallback) {
  const value = await env.CHATBOT_KV.get(key);
  if (!value) return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

async function sendMessage(env, chatId, text) {
  return telegram(env, "sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
  });
}

async function copyMessage(env, chatId, fromChatId, messageId) {
  return telegram(env, "copyMessage", {
    chat_id: chatId,
    from_chat_id: fromChatId,
    message_id: messageId,
  });
}

async function telegram(env, method, payload) {
  const response = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  return response.json();
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function json(value, init = {}) {
  return new Response(JSON.stringify(value), {
    ...init,
    headers: { "content-type": "application/json; charset=utf-8", ...(init.headers || {}) },
  });
}
