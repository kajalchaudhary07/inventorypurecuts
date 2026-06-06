const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");

const { admin, db } = require("./shared");

function resolveOrderUserId(orderData = {}) {
  const candidates = [
    orderData.userId,
    orderData.uid,
    orderData.customerId,
    orderData.userUid,
    orderData.user && (orderData.user.id || orderData.user.uid),
    orderData.customer && (orderData.customer.id || orderData.customer.uid),
  ];

  for (const candidate of candidates) {
    const value = String(candidate || "").trim();
    if (value) return value;
  }

  return "";
}

function getOrderProductLabel(orderData = {}) {
  const items = Array.isArray(orderData.items) ? orderData.items : [];

  const names = items
    .map((item) =>
      String(
        item?.productName || item?.name || item?.title || item?.product?.name || ""
      ).trim()
    )
    .filter(Boolean);

  if (names.length === 0) return "your order";
  if (names.length === 1) return names[0];

  const extraCount = names.length - 1;
  return `${names[0]} +${extraCount} more item${extraCount > 1 ? "s" : ""}`;
}

exports.onOrderPlacedNotification = onDocumentCreated("orders/{orderId}", async (event) => {
  const orderId = String(event.params?.orderId || "").trim();
  const orderData = event.data?.data() || {};

  const userId = resolveOrderUserId(orderData);
  if (!userId) {
    logger.warn("[OrderPlacedNotification] Missing user id on order", { orderId });
    return;
  }

  const userSnap = await db.collection("users").doc(userId).get();
  if (!userSnap.exists || !userSnap.data()) {
    logger.warn("[OrderPlacedNotification] User not found for order", {
      orderId,
      userId,
    });
    return;
  }

  const userData = userSnap.data() || {};
  const fcmToken = String(userData.fcmToken || "").trim();
  if (!fcmToken) {
    logger.warn("[OrderPlacedNotification] Missing FCM token for user", {
      orderId,
      userId,
    });
    return;
  }

  const productLabel = getOrderProductLabel(orderData);
  const title = "Order Placed";
  const message = `Your order for ${productLabel} has been placed.`;

  try {
    const messageId = await admin.messaging().send({
      token: fcmToken,
      notification: {
        title,
        body: message,
      },
      data: {
        eventType: "order_placed",
        orderId,
        title,
        message,
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
    });

    logger.info("[OrderPlacedNotification] Push sent", {
      orderId,
      userId,
      messageId,
    });
  } catch (error) {
    logger.error("[OrderPlacedNotification] Failed to send push", {
      orderId,
      userId,
      error: String(error?.message || error),
    });
  }
});
