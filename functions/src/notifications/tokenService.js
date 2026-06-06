const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { admin, db, TOPICS } = require("./shared");

exports.registerFcmToken = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const uid = request.auth.uid;
  const fcmToken = String(request.data?.fcmToken || "").trim();
  if (!fcmToken) {
    throw new HttpsError("invalid-argument", "fcmToken is required.");
  }

  await db
    .collection("users")
    .doc(uid)
    .set(
      {
        fcmToken,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  await admin.messaging().subscribeToTopic([fcmToken], TOPICS.ALL_USERS);

  return {
    success: true,
    topic: TOPICS.ALL_USERS,
  };
});
