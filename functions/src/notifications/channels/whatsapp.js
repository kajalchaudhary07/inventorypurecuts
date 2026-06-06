const logger = require("firebase-functions/logger");

async function sendWhatsAppMessage(phone, message) {
  // TODO: integrate Twilio or WhatsApp Business API.
  logger.info("[Notification][WhatsApp][Planned]", {
    phone: String(phone || "").trim(),
    messagePreview: String(message || "").slice(0, 120),
  });

  return {
    planned: true,
    sent: 0,
  };
}

async function sendWhatsAppChannel({ targetType, users, message }) {
  if (targetType === "specific") {
    const user = users[0] || {};
    await sendWhatsAppMessage(user.phone, message);
    return {
      planned: true,
      sent: 0,
    };
  }

  logger.info("[Notification][WhatsApp][Planned][Broadcast]", {
    mode: "all",
  });

  return {
    planned: true,
    sent: 0,
  };
}

module.exports = {
  sendWhatsAppMessage,
  sendWhatsAppChannel,
};
