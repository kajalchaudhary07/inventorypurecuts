const { HttpsError } = require("firebase-functions/v2/https");

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

async function resolveSpecificTarget({ db, orderId }) {
  const orderRef = db.collection("orders").doc(orderId);
  const orderSnap = await orderRef.get();

  if (!orderSnap.exists || !orderSnap.data()) {
    throw new HttpsError("not-found", `Order ${orderId} not found.`);
  }

  const orderData = orderSnap.data() || {};
  const userId = resolveOrderUserId(orderData);
  if (!userId) {
    throw new HttpsError(
      "failed-precondition",
      `Order ${orderId} does not have a valid userId.`
    );
  }

  const userRef = db.collection("users").doc(userId);
  const userSnap = await userRef.get();
  if (!userSnap.exists || !userSnap.data()) {
    throw new HttpsError("not-found", `User ${userId} not found for order ${orderId}.`);
  }

  const userData = userSnap.data() || {};

  return {
    mode: "specific",
    userIds: [userId],
    users: [
      {
        id: userId,
        name: String(userData.name || "").trim(),
        phone: String(userData.phone || "").trim(),
        fcmToken: String(userData.fcmToken || "").trim(),
      },
    ],
    order: {
      id: orderId,
      orderRef: String(
        orderData.orderId || orderData.orderRef || orderData.code || orderData.number || orderId
      ).trim(),
      status: String(orderData.status || orderData.orderStatus || "").trim(),
    },
  };
}

async function resolveAllTarget() {
  return {
    mode: "all",
    userIds: [],
    users: [],
    order: null,
  };
}

module.exports = {
  resolveSpecificTarget,
  resolveAllTarget,
};
