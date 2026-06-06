async function createNotificationRecord({
  db,
  admin,
  title,
  message,
  targetType,
  userIds,
  orderId,
  orderRef,
  type,
  channels,
  createdBy,
}) {
  const payload = {
    title,
    message,
    targetType,
    userIds: Array.isArray(userIds) ? userIds : [],
    orderId: orderId || null,
    orderRef: orderRef || null,
    type: type || (targetType === "all" ? "broadcast" : "order_status"),
    channels: {
      push: Boolean(channels.push),
      whatsapp: Boolean(channels.whatsapp),
      sms: Boolean(channels.sms),
    },
    audience: targetType === "all" ? "all_users" : "specific_user",
    status: "pending",
    createdByUid: String(createdBy || "").trim() || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  return await db.collection("notifications").add(payload);
}

async function updateNotificationRecord({ db, admin, notificationId, data }) {
  await db
    .collection("notifications")
    .doc(notificationId)
    .set(
      {
        ...data,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
}

module.exports = {
  createNotificationRecord,
  updateNotificationRecord,
};
