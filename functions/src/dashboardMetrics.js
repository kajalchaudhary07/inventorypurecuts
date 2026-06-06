const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();
const { FieldValue } = admin.firestore;

const AGGREGATE_DOC_PATH = "aggregates/dashboard";

const normalizeAmount = (raw = {}) => {
  const amount = Number(
    raw.amount ??
      raw.total ??
      raw.totalAmount ??
      raw.grandTotal ??
      raw.payableAmount ??
      0
  );
  return Number.isFinite(amount) ? amount : 0;
};

const normalizeStatus = (raw = {}) => {
  return String(raw.orderStatus || raw.status || "placed")
    .trim()
    .toLowerCase();
};

const isPendingStatus = (status) => {
  return (
    status !== "" &&
    status !== "delivered" &&
    status !== "cancelled" &&
    status !== "refunded"
  );
};

const toCounterDelta = (beforeExists, afterExists) => {
  if (!beforeExists && afterExists) return 1;
  if (beforeExists && !afterExists) return -1;
  return 0;
};

const resolveOrderUserId = (orderData = {}) => {
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
};

const assertAdminCaller = (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const claims = request.auth.token || {};
  if (claims.admin !== true && claims.superAdmin !== true) {
    throw new HttpsError(
      "permission-denied",
      "Only admins can fetch dashboard metrics."
    );
  }
};

const getSafeCount = async (queryRef) => {
  try {
    const snapshot = await queryRef.count().get();
    return Number(snapshot?.data()?.count || 0);
  } catch (error) {
    logger.warn("[DashboardMetrics] Count query failed", {
      error: String(error?.message || error),
    });
    return 0;
  }
};

const chunk = (arr, size) => {
  const out = [];
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size));
  }
  return out;
};

exports.onOrderMetricsWrite = onDocumentWritten(
  "orders/{orderId}",
  async (event) => {
    const beforeData = event.data?.before?.data() || null;
    const afterData = event.data?.after?.data() || null;

    const beforeExists = Boolean(beforeData);
    const afterExists = Boolean(afterData);

    if (!beforeExists && !afterExists) return;

    const beforeAmount = beforeExists ? normalizeAmount(beforeData) : 0;
    const afterAmount = afterExists ? normalizeAmount(afterData) : 0;
    const amountDelta = afterAmount - beforeAmount;

    const beforePending =
      beforeExists && isPendingStatus(normalizeStatus(beforeData)) ? 1 : 0;
    const afterPending =
      afterExists && isPendingStatus(normalizeStatus(afterData)) ? 1 : 0;
    const pendingDelta = afterPending - beforePending;

    const ordersDelta = toCounterDelta(beforeExists, afterExists);
    const beforeOwnerId = beforeExists ? resolveOrderUserId(beforeData) : "";
    const afterOwnerId = afterExists ? resolveOrderUserId(afterData) : "";

    const aggregateRef = db.doc(AGGREGATE_DOC_PATH);

    await db.runTransaction(async (txn) => {
      const snapshot = await txn.get(aggregateRef);
      const prev = snapshot.exists ? snapshot.data() || {} : {};

      const prevOrders = Number(prev.totalOrders || 0);
      const prevPending = Number(prev.pendingOrders || 0);
      const prevRevenue = Number(prev.totalRevenue || 0);

      const nextOrders = Math.max(0, prevOrders + ordersDelta);
      const nextPending = Math.max(0, prevPending + pendingDelta);
      const nextRevenue = Math.max(0, prevRevenue + amountDelta);

      txn.set(
        aggregateRef,
        {
          totalOrders: nextOrders,
          pendingOrders: nextPending,
          totalRevenue: nextRevenue,
          updatedAt: FieldValue.serverTimestamp(),
          ...(snapshot.exists
            ? {}
            : {
                createdAt: FieldValue.serverTimestamp(),
              }),
        },
        { merge: true }
      );

      const applyUserOrdersDelta = async (uid, delta) => {
        const safeUid = String(uid || "").trim();
        if (!safeUid || !delta) return;

        const userRef = db.collection("users").doc(safeUid);
        const userSnap = await txn.get(userRef);
        const prevUser = userSnap.exists ? userSnap.data() || {} : {};
        const prevCount = Number(prevUser.ordersCount || 0);
        const nextCount = Math.max(0, prevCount + delta);

        txn.set(
          userRef,
          {
            ordersCount: nextCount,
            hasPurchased: nextCount > 0,
            updatedAt: FieldValue.serverTimestamp(),
            ...(userSnap.exists
              ? {}
              : {
                  createdAt: FieldValue.serverTimestamp(),
                }),
          },
          { merge: true }
        );
      };

      if (!beforeOwnerId && afterOwnerId) {
        await applyUserOrdersDelta(afterOwnerId, 1);
      } else if (beforeOwnerId && !afterOwnerId) {
        await applyUserOrdersDelta(beforeOwnerId, -1);
      } else if (beforeOwnerId && afterOwnerId && beforeOwnerId !== afterOwnerId) {
        await applyUserOrdersDelta(beforeOwnerId, -1);
        await applyUserOrdersDelta(afterOwnerId, 1);
      }
    });
  }
);

exports.getDashboardMetricsSnapshot = onCall(async (request) => {
  assertAdminCaller(request);

  const aggregateSnap = await db.doc(AGGREGATE_DOC_PATH).get();
  const aggregate = aggregateSnap.exists ? aggregateSnap.data() || {} : {};

  const [productsCount, customersCount, approvedReviews] = await Promise.all([
    getSafeCount(db.collection("products")),
    getSafeCount(db.collection("users")),
    getSafeCount(
      db.collectionGroup("reviews").where("approved", "==", true)
    ),
  ]);

  return {
    ok: true,
    source: aggregateSnap.exists ? "aggregate_doc" : "count_fallback",
    totalRevenue: Number(aggregate.totalRevenue || 0),
    ordersCount: Number(aggregate.totalOrders || 0),
    pendingOrders: Number(aggregate.pendingOrders || 0),
    productsCount,
    customersCount,
    approvedReviews,
    updatedAt: aggregate.updatedAt || null,
    lastBackfillAt: aggregate.lastBackfillAt || null,
  };
});

exports.rebuildOrderCounters = onCall(async (request) => {
  assertAdminCaller(request);

  const orderOwnerCount = new Map();
  let totalOrders = 0;
  let pendingOrders = 0;
  let totalRevenue = 0;

  const pageSize = 1000;
  let lastDoc = null;

  while (true) {
    let orderQuery = db
      .collection("orders")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(pageSize);

    if (lastDoc) {
      orderQuery = orderQuery.startAfter(lastDoc);
    }

    const orderSnap = await orderQuery.get();
    if (orderSnap.empty) break;

    orderSnap.docs.forEach((orderDoc) => {
      const data = orderDoc.data() || {};
      totalOrders += 1;
      totalRevenue += normalizeAmount(data);
      if (isPendingStatus(normalizeStatus(data))) {
        pendingOrders += 1;
      }

      const ownerId = resolveOrderUserId(data);
      if (ownerId) {
        orderOwnerCount.set(ownerId, Number(orderOwnerCount.get(ownerId) || 0) + 1);
      }
    });

    lastDoc = orderSnap.docs[orderSnap.docs.length - 1];
    if (orderSnap.size < pageSize) break;
  }

  const upserts = Array.from(orderOwnerCount.entries()).map(([uid, count]) => ({
    uid,
    ordersCount: count,
  }));

  for (const group of chunk(upserts, 400)) {
    const batch = db.batch();
    group.forEach((item) => {
      const userRef = db.collection("users").doc(item.uid);
      batch.set(
        userRef,
        {
          ordersCount: Number(item.ordersCount || 0),
          hasPurchased: Number(item.ordersCount || 0) > 0,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
    await batch.commit();
  }

  const staleUsersSnap = await db
    .collection("users")
    .where("ordersCount", ">", 0)
    .get();

  const staleUsers = staleUsersSnap.docs
    .map((d) => d.id)
    .filter((uid) => !orderOwnerCount.has(uid));

  for (const group of chunk(staleUsers, 400)) {
    const batch = db.batch();
    group.forEach((uid) => {
      const userRef = db.collection("users").doc(uid);
      batch.set(
        userRef,
        {
          ordersCount: 0,
          hasPurchased: false,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
    await batch.commit();
  }

  await db.doc(AGGREGATE_DOC_PATH).set(
    {
      totalOrders,
      pendingOrders,
      totalRevenue,
      updatedAt: FieldValue.serverTimestamp(),
      createdAt: FieldValue.serverTimestamp(),
      lastBackfillAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  return {
    ok: true,
    totalOrders,
    pendingOrders,
    totalRevenue,
    usersWithOrders: upserts.length,
    staleUsersReset: staleUsers.length,
  };
});
