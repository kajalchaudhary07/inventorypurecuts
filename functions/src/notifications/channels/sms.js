const logger = require("firebase-functions/logger");

async function sendSMS(phone, message) {
  // TODO: integrate SMS provider (Twilio / SNS / etc.).
  logger.info("[Notification][SMS][Planned]", {
    phone: String(phone || "").trim(),
    messagePreview: String(message || "").slice(0, 120),
  });

  return {
    planned: true,
    sent: 0,
  };
}

async function sendSMSChannel({ targetType, users, message }) {
  if (targetType === "specific") {
    const user = users[0] || {};
    await sendSMS(user.phone, message);
    return {
      planned: true,
      sent: 0,
    };
  }

  logger.info("[Notification][SMS][Planned][Broadcast]", {
    mode: "all",
  });

  return {
    planned: true,
    sent: 0,
  };
}

module.exports = {
  sendSMS,
  sendSMSChannel,
};
