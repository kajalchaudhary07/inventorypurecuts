const logger = require("firebase-functions/logger");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { createOrderFromPaymentSuccess } = require("./paymentRepository");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();

exports.reconcileSuccessfulPayments = onSchedule(
  {
    schedule: "every 5 minutes",
    region: "asia-south1",
    timeZone: "Asia/Kolkata",
    memory: "256MiB",
    timeoutSeconds: 120,
  },
  async () => {
    const [pendingSnap, failedNoDraftSnap, fallbackSnap] = await Promise.all([
      db
        .collection("payments")
        .where("status", "==", "success")
        .where("hashVerified", "==", true)
        .where("orderPlacementStatus", "==", "pending")
        .limit(100)
        .get(),
      db
        .collection("payments")
        .where("status", "==", "success")
        .where("hashVerified", "==", true)
        .where("orderPlacementStatus", "==", "failed-no-draft")
        .limit(100)
        .get(),
      db
        .collection("payments")
        .where("status", "==", "success")
        .where("hashVerified", "==", true)
        .orderBy("updatedAt", "desc")
        .limit(100)
        .get(),
    ]);

    const docMap = new Map();
    for (const snap of [pendingSnap, failedNoDraftSnap, fallbackSnap]) {
      for (const doc of snap.docs) {
        docMap.set(doc.id, doc);
      }
    }

    const docs = Array.from(docMap.values());

    if (docs.length === 0) {
      logger.info("[PayU][Reconcile] No successful payments found.");
      return;
    }

    let scanned = 0;
    let placed = 0;
    let skipped = 0;

    for (const doc of docs) {
      scanned += 1;
      const data = doc.data() || {};
      const placementStatus = String(data.orderPlacementStatus || "").trim().toLowerCase();
      if (placementStatus === "placed") {
        skipped += 1;
        continue;
      }

      try {
        const result = await createOrderFromPaymentSuccess(doc.id);
        if (result.placed) {
          placed += 1;
        }
      } catch (error) {
        logger.error("[PayU][Reconcile] Failed for txnid", {
          txnid: doc.id,
          error: String(error?.message || error),
        });
      }
    }

    logger.info("[PayU][Reconcile] Cycle completed", {
      scanned,
      placed,
      skipped,
    });
  }
);
