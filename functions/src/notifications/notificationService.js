const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

const { admin, db, TOPICS } = require("./shared");
const { validateSendNotificationInput } = require("./validators");
const { resolveSpecificTarget, resolveAllTarget } = require("./targets");
const {
  createNotificationRecord,
  updateNotificationRecord,
} = require("./repository");
const { sendPushNotification } = require("./channels/push");
const { sendWhatsAppChannel } = require("./channels/whatsapp");
const { sendSMSChannel } = require("./channels/sms");

function assertAdminCaller(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const claims = request.auth.token || {};
  if (claims.admin !== true && claims.superAdmin !== true) {
    throw new HttpsError("permission-denied", "Only admins can send notifications.");
  }
}

exports.sendNotification = onCall(async (request) => {
  assertAdminCaller(request);

  const input = validateSendNotificationInput(request.data || {});

  const target =
    input.targetType === "specific"
      ? await resolveSpecificTarget({ db, orderId: input.orderId })
      : await resolveAllTarget();

  const notificationRef = await createNotificationRecord({
    db,
    admin,
    title: input.title,
    message: input.message,
    targetType: input.targetType,
    userIds: target.userIds,
    orderId: input.orderId || null,
    orderRef: target.order?.orderRef || null,
    type: input.type,
    channels: input.channels,
    createdBy: request.auth.uid,
  });

  let pushSent = 0;
  const channelErrors = {};
  const channelResults = {};

  if (input.channels.push) {
    try {
      const pushResult = await sendPushNotification({
        admin,
        topicName: TOPICS.ALL_USERS,
        targetType: input.targetType,
        users: target.users,
        title: input.title,
        message: input.message,
      });
      pushSent = Number(pushResult.sent || 0);
      channelResults.push = pushResult;
    } catch (error) {
      const msg = String(error?.message || error);
      channelErrors.push = msg;
      logger.error("[Notification][Push] send failed", {
        notificationId: notificationRef.id,
        error: msg,
      });
    }
  }

  if (input.channels.whatsapp) {
    try {
      const whatsappResult = await sendWhatsAppChannel({
        targetType: input.targetType,
        users: target.users,
        message: input.message,
      });
      channelResults.whatsapp = whatsappResult;
    } catch (error) {
      const msg = String(error?.message || error);
      channelErrors.whatsapp = msg;
      logger.error("[Notification][WhatsApp] send failed", {
        notificationId: notificationRef.id,
        error: msg,
      });
    }
  }

  if (input.channels.sms) {
    try {
      const smsResult = await sendSMSChannel({
        targetType: input.targetType,
        users: target.users,
        message: input.message,
      });
      channelResults.sms = smsResult;
    } catch (error) {
      const msg = String(error?.message || error);
      channelErrors.sms = msg;
      logger.error("[Notification][SMS] send failed", {
        notificationId: notificationRef.id,
        error: msg,
      });
    }
  }

  const selectedChannelsCount = [
    input.channels.push,
    input.channels.whatsapp,
    input.channels.sms,
  ].filter(Boolean).length;
  const failedChannelsCount = Object.keys(channelErrors).length;
  const success = failedChannelsCount < selectedChannelsCount;

  await updateNotificationRecord({
    db,
    admin,
    notificationId: notificationRef.id,
    data: {
      status: success ? "sent" : "failed",
      sentAt: admin.firestore.FieldValue.serverTimestamp(),
      channelResults,
      errors: channelErrors,
      pushSent,
    },
  });

  return {
    success,
    pushSent,
    whatsappPlanned: Boolean(input.channels.whatsapp),
    smsPlanned: Boolean(input.channels.sms),
  };
});
