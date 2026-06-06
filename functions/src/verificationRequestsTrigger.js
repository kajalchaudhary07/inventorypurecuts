const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { defineSecret } = require("firebase-functions/params");
const axios = require("axios");

const TELEGRAM_BOT_TOKEN = defineSecret("TELEGRAM_BOT_TOKEN");
const TELEGRAM_ADMIN_CHAT_IDS = defineSecret("TELEGRAM_ADMIN_CHAT_IDS");
const TELEGRAM_CONFIG_VERSION = "verification-telegram-v2";

function firstNonEmpty(...values) {
  for (const value of values) {
    const resolved = String(value ?? "").trim();
    if (resolved) return resolved;
  }
  return "";
}

function normalizeChatIds(rawValue) {
  const unique = new Set();

  String(rawValue || "")
    .split(/[\n,;]+/)
    .map((part) => part.trim())
    .filter(Boolean)
    .forEach((id) => unique.add(id));

  return Array.from(unique);
}

function readSecretValue(secretParam) {
  try {
    return String(secretParam?.value?.() || "").trim();
  } catch (_) {
    return "";
  }
}

function firstNonEmptyFromEnv(varNames) {
  for (const varName of varNames) {
    const value = String(process.env[varName] || "").trim();
    if (value) {
      return { value, source: varName };
    }
  }

  return { value: "", source: "" };
}

function resolveTelegramConfig() {
  const secretToken = readSecretValue(TELEGRAM_BOT_TOKEN);
  const secretChatIds = readSecretValue(TELEGRAM_ADMIN_CHAT_IDS);

  const envToken = firstNonEmptyFromEnv([
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_TOKEN",
  ]);
  const envChatIds = firstNonEmptyFromEnv([
    "TELEGRAM_ADMIN_CHAT_IDS",
    "TELEGRAM_CHAT_IDS",
  ]);

  const token = secretToken || envToken.value;
  const rawChatIds = secretChatIds || envChatIds.value;

  return {
    token,
    chatIds: normalizeChatIds(rawChatIds),
    tokenSource: secretToken ? "secret:TELEGRAM_BOT_TOKEN" : envToken.source || "missing",
    chatIdSource: secretChatIds
      ? "secret:TELEGRAM_ADMIN_CHAT_IDS"
      : envChatIds.source || "missing",
  };
}

async function resolveBotIdentity(token) {
  try {
    const response = await axios.get(
      `https://api.telegram.org/bot${token}/getMe`,
      { timeout: 10000 }
    );

    return String(response?.data?.result?.username || "").trim();
  } catch (error) {
    logger.error("[VerificationTelegram] Token validation failed", {
      errorMessage: String(error?.message || error),
      status: error?.response?.status,
      telegramError: error?.response?.data,
    });
    return "";
  }
}

function buildMessage({ requestId, userId, gstNumber, udyamNumber }) {
  return [
    "🚀 New User Verification Request",
    "",
    `Request ID: ${requestId || "Unknown"}`,
    `User ID: ${userId || "Not Provided"}`,
    `GST Number: ${gstNumber || "Not Provided"}`,
    `Udyam Number: ${udyamNumber || "Not Provided"}`,
    "",
    "Review this request in the admin dashboard.",
  ].join("\n");
}

exports.onVerificationRequestCreated = onDocumentCreated(
  {
    document: "verificationRequests/{requestId}",
    secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_ADMIN_CHAT_IDS],
  },
  async (event) => {
    const requestId = String(event.params?.requestId || "").trim();
    const data = event.data?.data() || {};

    const userId = firstNonEmpty(
      data.userId,
      data.uid,
      data.customerId,
      data.createdBy,
      data.user && (data.user.id || data.user.uid)
    );

    const gstNumber = firstNonEmpty(
      data.gstNumber,
      data.gst,
      data.gstin,
      data.gstNo,
      data.gst_number
    );

    const udyamNumber = firstNonEmpty(
      data.udyamNumber,
      data.udyam,
      data.udyamNo,
      data.udyam_number,
      data.msmeNumber
    );

    const { token, chatIds, tokenSource, chatIdSource } =
      resolveTelegramConfig();

    if (!token) {
      logger.error("[VerificationTelegram] Missing bot token", {
        requestId,
        configVersion: TELEGRAM_CONFIG_VERSION,
        tokenSource,
      });
      return;
    }

    if (chatIds.length === 0) {
      logger.error("[VerificationTelegram] Missing admin chat IDs", {
        requestId,
        configVersion: TELEGRAM_CONFIG_VERSION,
        chatIdSource,
      });
      return;
    }

    const botUsername = await resolveBotIdentity(token);
    if (!botUsername) {
      logger.error("[VerificationTelegram] Aborting due to invalid bot token", {
        requestId,
        configVersion: TELEGRAM_CONFIG_VERSION,
        tokenSource,
        botTokenFirst8: token.slice(0, 8),
      });
      return;
    }

    const url = `https://api.telegram.org/bot${token}/sendMessage`;
    const message = buildMessage({ requestId, userId, gstNumber, udyamNumber });

    logger.info("[VerificationTelegram] Sending Telegram notification", {
      requestId,
      chatIds,
      configVersion: TELEGRAM_CONFIG_VERSION,
      tokenSource,
      chatIdSource,
      botUsername,
      botTokenFirst8: token.slice(0, 8),
    });

    const results = await Promise.allSettled(
      chatIds.map((chatId) =>
        axios.post(
          url,
          {
            chat_id: chatId,
            text: message,
            disable_notification: false,
          },
          {
            timeout: 15000,
          }
        )
      )
    );

    let delivered = 0;
    let failed = 0;

    results.forEach((result, index) => {
      const chatId = chatIds[index];
      if (result.status === "fulfilled") {
        delivered += 1;
        return;
      }

      failed += 1;
      logger.error("[VerificationTelegram] Failed to send message", {
        requestId,
        chatId,
        errorMessage: String(result.reason?.message || result.reason),
        status: result.reason?.response?.status,
        code: result.reason?.code,
        telegramError: result.reason?.response?.data,
      });
    });

    logger.info("[VerificationTelegram] Notification dispatch complete", {
      requestId,
      delivered,
      failed,
      recipients: chatIds.length,
      botUsername,
      configVersion: TELEGRAM_CONFIG_VERSION,
      hasGst: Boolean(gstNumber),
      hasUdyam: Boolean(udyamNumber),
      hasUserId: Boolean(userId),
    });
  }
);
