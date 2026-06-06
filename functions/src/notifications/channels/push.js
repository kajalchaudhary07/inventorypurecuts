const { HttpsError } = require("firebase-functions/v2/https");

async function sendPushNotification({ admin, topicName, targetType, users, title, message }) {
  const basePayload = {
    notification: {
      title,
      body: message,
    },
    data: {
      title: String(title || ""),
      message: String(message || ""),
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    android: {
      priority: "high",
      notification: {
        channelId: "high_importance_channel",
      },
    },
    apns: {
      headers: {
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  };

  if (targetType === "specific") {
    const user = users[0] || {};
    const token = String(user.fcmToken || "").trim();
    if (!token) {
      throw new HttpsError(
        "failed-precondition",
        "Target user does not have an FCM token."
      );
    }

    const responseId = await admin.messaging().send({
      token,
      ...basePayload,
    });

    return {
      sent: 1,
      messageIds: [responseId],
      mode: "token",
    };
  }

  const responseId = await admin.messaging().send({
    topic: topicName,
    ...basePayload,
  });

  return {
    sent: 1,
    messageIds: [responseId],
    mode: "topic",
  };
}

module.exports = {
  sendPushNotification,
};
