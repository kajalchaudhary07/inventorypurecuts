const { HttpsError } = require("firebase-functions/v2/https");

function asBool(value, fallback = false) {
  if (typeof value === "boolean") return value;
  if (value === 1 || value === "1" || value === "true") return true;
  if (value === 0 || value === "0" || value === "false") return false;
  return fallback;
}

function normalizeChannels(rawChannels = {}) {
  const channels = {
    push: asBool(rawChannels.push, true),
    whatsapp: asBool(rawChannels.whatsapp, false),
    sms: asBool(rawChannels.sms, false),
  };

  if (!channels.push && !channels.whatsapp && !channels.sms) {
    throw new HttpsError(
      "invalid-argument",
      "At least one channel must be enabled (push, whatsapp, or sms)."
    );
  }

  return channels;
}

function validateSendNotificationInput(raw = {}) {
  const targetType = String(raw.targetType || "").trim().toLowerCase();
  if (!["specific", "all"].includes(targetType)) {
    throw new HttpsError(
      "invalid-argument",
      "targetType must be either 'specific' or 'all'."
    );
  }

  const title = String(raw.title || "").trim();
  const message = String(raw.message || "").trim();

  if (!title) {
    throw new HttpsError("invalid-argument", "title is required.");
  }

  if (!message) {
    throw new HttpsError("invalid-argument", "message is required.");
  }

  const orderId = String(raw.orderId || "").trim();
  if (targetType === "specific" && !orderId) {
    throw new HttpsError(
      "invalid-argument",
      "orderId is required when targetType is 'specific'."
    );
  }

  const channels = normalizeChannels(raw.channels || {});
  const type = String(raw.type || "").trim();

  return {
    targetType,
    orderId,
    title,
    message,
    channels,
    type,
  };
}

module.exports = {
  validateSendNotificationInput,
};
