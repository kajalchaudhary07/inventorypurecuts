const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();

async function createReconciliationAlert({ txnid, reason, payment }) {
  const cleanTxnId = cleanString(txnid);
  if (!cleanTxnId) return;

  await db
    .collection("paymentReconciliationAlerts")
    .doc(cleanTxnId)
    .set(
      {
        txnid: cleanTxnId,
        reason: cleanString(reason),
        paymentStatus: cleanString(payment?.status || ""),
        payuStatus: cleanString(payment?.payuStatus || ""),
        userId: cleanString(payment?.userId || ""),
        amount: normalizeAmountString(payment?.amount || "0.00"),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
}

function cleanString(value) {
  return String(value || "").trim();
}

function normalizeOrderRef(value) {
  const clean = cleanString(value);
  if (!clean) return "";
  return clean.startsWith("#") ? clean.slice(1).trim() : clean;
}

function normalizeAmountString(value) {
  const raw = cleanString(value);
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return "0.00";
  return parsed.toFixed(2);
}

function parsePositiveNumber(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return parsed;
}

function generateOrderRefFromTxn(txnid) {
  const now = new Date();
  const ymd = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`;
  const suffix = cleanString(txnid).replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(-6).padStart(6, "0");
  return `PC-${ymd}-${suffix}`;
}

function buildOrderDocIdFromTxn(txnid) {
  const safe = cleanString(txnid).replace(/[^a-zA-Z0-9_-]/g, "_");
  return `payu_${safe || "unknown"}`;
}

function buildEditOrderDocId(sourceKey) {
  const safe = cleanString(sourceKey).replace(/[^a-zA-Z0-9_-]/g, "_");
  return `edit_${safe || "unknown"}`;
}

function sanitizeOrderDraft(raw = {}) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;

  const uid = cleanString(raw.uid || raw.userId || raw.customerId);
  const itemsRaw = Array.isArray(raw.items) ? raw.items : [];
  const items = itemsRaw
    .filter((item) => item && typeof item === "object" && !Array.isArray(item))
    .map((item) => {
      const quantityParsed = Number(item.quantity ?? item.qty ?? 1);
      const priceParsed = Number(item.price ?? 0);
      return {
        id: cleanString(item.id || item.productId),
        productId: cleanString(item.productId || item.id),
        name: cleanString(item.name),
        brand: cleanString(item.brand),
        image: cleanString(item.image),
        price: Number.isFinite(priceParsed) ? priceParsed : 0,
        originalPrice: Number.isFinite(Number(item.originalPrice)) ? Number(item.originalPrice) : (Number.isFinite(priceParsed) ? priceParsed : 0),
        size: cleanString(item.size),
        tag: cleanString(item.tag),
        tags: Array.isArray(item.tags) ? item.tags.map((v) => cleanString(v)).filter(Boolean) : [],
        category: cleanString(item.category),
        subCategory: cleanString(item.subCategory),
        quantity: Number.isFinite(quantityParsed) && quantityParsed > 0 ? quantityParsed : 1,
      };
    })
    .filter((item) => item.productId);

  if (!uid || items.length === 0) return null;

  const bill = raw.billDetails && typeof raw.billDetails === "object" ? raw.billDetails : {};
  const itemTotal = Number(raw.itemTotal ?? bill.itemTotal ?? 0);
  const deliveryCharge = Number(raw.deliveryCharge ?? bill.deliveryCharge ?? 0);
  const handlingCharge = Number(raw.handlingCharge ?? bill.handlingCharge ?? 0);
  const explicitGrandTotal = Number(raw.grandTotal ?? bill.grandTotal ?? raw.total ?? 0);
  const computedFromItems = items.reduce((sum, item) => {
    const price = Number(item.price || 0);
    const qty = Number(item.quantity || 1);
    return sum + (Number.isFinite(price) ? price : 0) * (Number.isFinite(qty) ? qty : 1);
  }, 0);
  const fallbackGrand = computedFromItems +
    (Number.isFinite(deliveryCharge) ? deliveryCharge : 0) +
    (Number.isFinite(handlingCharge) ? handlingCharge : 0);
  const grandTotal = Number.isFinite(explicitGrandTotal) && explicitGrandTotal > 0
    ? explicitGrandTotal
    : (fallbackGrand > 0 ? fallbackGrand : computedFromItems);

  const editMetaRaw = raw.editMeta && typeof raw.editMeta === "object" ? raw.editMeta : null;
  const editMeta = editMetaRaw
    ? {
        isEditOrder: editMetaRaw.isEditOrder === true,
        sourceOrderDocumentId: cleanString(editMetaRaw.sourceOrderDocumentId || editMetaRaw.sourceOrderId),
        sourceOrderId: cleanString(editMetaRaw.sourceOrderId || editMetaRaw.sourceOrderDocumentId),
        sourceOrderRef: cleanString(editMetaRaw.sourceOrderRef),
        windowHours: parsePositiveNumber(editMetaRaw.windowHours),
        lockedQuantities:
          editMetaRaw.lockedQuantities && typeof editMetaRaw.lockedQuantities === "object"
            ? editMetaRaw.lockedQuantities
            : {},
        originalCreatedAt: cleanString(editMetaRaw.originalCreatedAt),
        originalTotalAmount: parsePositiveNumber(editMetaRaw.originalTotalAmount),
        originalItemCount: parsePositiveNumber(editMetaRaw.originalItemCount),
        originalPaymentMethod: cleanString(editMetaRaw.originalPaymentMethod),
      }
    : null;

  return {
    uid,
    userId: uid,
    customerId: uid,
    orderRef: cleanString(raw.orderRef),
    paymentMethod: cleanString(raw.paymentMethod),
    customerName: cleanString(raw.customerName),
    customerEmail: cleanString(raw.customerEmail),
    customerPhone: cleanString(raw.customerPhone),
    deliveryAddress: raw.deliveryAddress && typeof raw.deliveryAddress === "object" ? raw.deliveryAddress : {},
    contactDetails: raw.contactDetails && typeof raw.contactDetails === "object" ? raw.contactDetails : {},
    billDetails: {
      itemTotal: Number.isFinite(itemTotal) ? itemTotal : 0,
      deliveryCharge: Number.isFinite(deliveryCharge) ? deliveryCharge : 0,
      handlingCharge: Number.isFinite(handlingCharge) ? handlingCharge : 0,
      grandTotal: Number.isFinite(grandTotal) ? grandTotal : 0,
    },
    editMeta,
    items,
  };
}

async function upsertPaymentRecord({
  txnid,
  userId,
  amount,
  status,
  hashVerified,
  payuStatus,
  mihpayid,
  mode,
  responseHashPrefix,
  orderDraft,
  orderRef,
  orderPlacementStatus,
}) {
  const cleanTxnId = cleanString(txnid);
  if (!cleanTxnId) {
    throw new Error("txnid is required");
  }

  const ref = db.collection("payments").doc(cleanTxnId);
  const existingSnap = await ref.get();
  const existing = existingSnap.exists ? existingSnap.data() || {} : {};

  const ownerUserId = cleanString(existing.userId) || cleanString(userId);
  const sanitizedOrderDraft = sanitizeOrderDraft(orderDraft) || existing.orderDraft || null;
  const incomingAmount = normalizeAmountString(amount);
  const existingAmount = normalizeAmountString(existing.amount || "0.00");
  const effectiveAmount = incomingAmount === "0.00" && existingAmount !== "0.00"
    ? existingAmount
    : incomingAmount;

  await ref.set(
    {
      txnid: cleanTxnId,
      userId: ownerUserId,
      amount: effectiveAmount,
      status: cleanString(status || "initiated").toLowerCase(),
      hashVerified: hashVerified === true,
      payuStatus: cleanString(payuStatus || "").toLowerCase(),
      mihpayid: cleanString(mihpayid),
      mode: cleanString(mode),
      responseHashPrefix: cleanString(responseHashPrefix),
      orderDraft: sanitizedOrderDraft,
      orderRef: cleanString(orderRef) || cleanString(existing.orderRef),
      orderPlacementStatus:
        cleanString(orderPlacementStatus) || cleanString(existing.orderPlacementStatus) || "pending",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      ...(existingSnap.exists ? {} : { createdAt: admin.firestore.FieldValue.serverTimestamp() }),
      ...(cleanString(status).toLowerCase() === "success"
        ? { successAt: admin.firestore.FieldValue.serverTimestamp() }
        : {}),
      ...(["failure", "cancelled"].includes(cleanString(status).toLowerCase())
        ? { failureAt: admin.firestore.FieldValue.serverTimestamp() }
        : {}),
    },
    { merge: true }
  );

  return ref.id;
}

async function getPaymentRecord(txnid) {
  const cleanTxnId = cleanString(txnid);
  if (!cleanTxnId) return null;
  const snap = await db.collection("payments").doc(cleanTxnId).get();
  if (!snap.exists) return null;
  return { id: snap.id, ...(snap.data() || {}) };
}

async function findOrderByPaymentTxnId(txnid) {
  const cleanTxnId = cleanString(txnid);
  if (!cleanTxnId) return null;
  const snap = await db.collection("orders").where("paymentTxnId", "==", cleanTxnId).limit(1).get();
  if (snap.empty) return null;
  const doc = snap.docs[0];
  return { id: doc.id, ...(doc.data() || {}) };
}

async function createOrderFromPaymentSuccess(txnid) {
  const cleanTxnId = cleanString(txnid);
  if (!cleanTxnId) {
    return { placed: false, reason: "missing-txnid" };
  }

  const existingOrder = await findOrderByPaymentTxnId(cleanTxnId);
  if (existingOrder) {
    const existingRef = cleanString(existingOrder.orderRef || existingOrder.orderId || existingOrder.orderNumber || "");
    await db.collection("payments").doc(cleanTxnId).set(
      {
        orderPlacementStatus: "placed",
        orderRef: existingRef,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    return { placed: true, orderRef: existingRef, orderId: existingOrder.id, reason: "already-exists" };
  }

  const payment = await getPaymentRecord(cleanTxnId);
  if (!payment) {
    return { placed: false, reason: "payment-not-found" };
  }

  const paymentStatus = cleanString(payment.status).toLowerCase();
  if (paymentStatus !== "success" || payment.hashVerified !== true) {
    return { placed: false, reason: "payment-not-verified-success" };
  }

  const draft = sanitizeOrderDraft(payment.orderDraft || {});
  if (!draft) {
    await db.collection("payments").doc(cleanTxnId).set(
      {
        orderPlacementStatus: "failed-no-draft",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    await createReconciliationAlert({
      txnid: cleanTxnId,
      reason: "missing-order-draft",
      payment,
    });
    return { placed: false, reason: "missing-order-draft" };
  }

  const editMeta = draft.editMeta || null;
  const isEditOrder = Boolean(editMeta && editMeta.isEditOrder === true);
  const editSourceKey = cleanString(
    editMeta?.sourceOrderDocumentId || editMeta?.sourceOrderId || editMeta?.sourceOrderRef
  );
  const useEditFlow = isEditOrder && editSourceKey.length > 0;
  const orderDoc = db.collection("orders").doc(
    useEditFlow ? buildEditOrderDocId(editSourceKey) : buildOrderDocIdFromTxn(cleanTxnId)
  );
  const editOrderRef = isEditOrder ? normalizeOrderRef(editMeta.sourceOrderRef) : "";
  const orderRef = editOrderRef || cleanString(draft.orderRef) || generateOrderRefFromTxn(cleanTxnId);

  let totalItems = 0;
  const normalizedItems = draft.items.map((item, index) => {
    const quantity = Number(item.quantity || 1);
    totalItems += Number.isFinite(quantity) && quantity > 0 ? quantity : 1;
    const productId = cleanString(item.productId || item.id);
    return {
      ...item,
      id: productId,
      productId,
      quantity: Number.isFinite(quantity) && quantity > 0 ? quantity : 1,
      orderId: orderRef,
      orderItemId: `${orderRef}-I${String(index + 1).padStart(2, "0")}`,
    };
  });

  const productIds = Array.from(new Set(normalizedItems.map((item) => cleanString(item.productId)).filter(Boolean)));
  const draftGrandTotal = parsePositiveNumber(draft.billDetails?.grandTotal);
  const paymentAmount = parsePositiveNumber(payment.amount);
  const computedItemsTotal = normalizedItems.reduce((sum, item) => {
    const price = Number(item.price || 0);
    const qty = Number(item.quantity || 1);
    return sum + (Number.isFinite(price) ? price : 0) * (Number.isFinite(qty) ? qty : 1);
  }, 0);
  const grandTotal = draftGrandTotal || paymentAmount || computedItemsTotal;

  const customerName = cleanString(draft.customerName || draft.contactDetails?.receiverName || "");
  const customerEmail = cleanString(draft.customerEmail);
  const customerPhone = cleanString(draft.customerPhone || draft.contactDetails?.phone || "");
  const paymentMethod = cleanString(draft.paymentMethod || "Pay Online");

  const addressLine = [
    cleanString(draft.deliveryAddress?.line1),
    cleanString(draft.deliveryAddress?.line2),
    cleanString(draft.deliveryAddress?.city),
    cleanString(draft.deliveryAddress?.state),
    cleanString(draft.deliveryAddress?.pincode),
  ].filter(Boolean).join(", ");

  let existingOrderRef = "";
  await db.runTransaction(async (tx) => {
    const existingSnap = await tx.get(orderDoc);
    if (existingSnap.exists) {
      const existingData = existingSnap.data() || {};
      existingOrderRef = cleanString(
        existingData.orderRef || existingData.orderId || existingData.orderNumber || orderRef
      );
      if (!useEditFlow) {
        tx.set(
          orderDoc,
          {
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            paymentTxnId: cleanTxnId,
          },
          { merge: true }
        );
        return;
      }
    }

    tx.set(orderDoc, {
      orderId: orderRef,
      orderRef,
      orderNumber: orderRef,
      uid: draft.uid,
      userId: draft.userId,
      customerId: draft.customerId,
      customerName,
      customerEmail,
      customerPhone,
      phone: customerPhone,
      deliveryAddress: draft.deliveryAddress,
      address: addressLine,
      contactDetails: draft.contactDetails,
      paymentMethod,
      paymentTxnId: cleanTxnId,
      paymentStatus: "paid",
      billDetails: draft.billDetails,
      items: normalizedItems,
      productIds,
      itemCount: normalizedItems.length,
      itemsCount: normalizedItems.length,
      totalItems,
      total: grandTotal,
      amount: grandTotal,
      totalAmount: grandTotal,
      grandTotal,
      deliveryPlaced: true,
      status: isEditOrder ? "edited" : "placed",
      orderStatus: isEditOrder ? "edited" : "placed",
      ...(editMeta
        ? {
            editMeta,
            isEditOrder: editMeta.isEditOrder === true,
            originalOrderDocumentId: editMeta.sourceOrderDocumentId,
            originalOrderId: editMeta.sourceOrderId,
            originalOrderRef: editMeta.sourceOrderRef,
            editWindowHours: editMeta.windowHours,
          }
        : {}),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: useEditFlow });
  });

  const effectiveOrderRef = existingOrderRef || orderRef;

  const sourceOrderDocumentId = cleanString(editMeta?.sourceOrderDocumentId || editMeta?.sourceOrderId);
  if (sourceOrderDocumentId && sourceOrderDocumentId !== orderDoc.id) {
    await db.collection("orders").doc(sourceOrderDocumentId).set(
      {
        status: "edited",
        orderStatus: "edited",
        editedAt: admin.firestore.FieldValue.serverTimestamp(),
        editedByOrderId: effectiveOrderRef,
        editedByOrderDocumentId: orderDoc.id,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  await db.collection("payments").doc(cleanTxnId).set(
    {
      orderPlacementStatus: "placed",
      orderRef: effectiveOrderRef,
      orderId: orderDoc.id,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  if (cleanString(draft.uid)) {
    const userUpdate = {
      deliveryAddressDetails: draft.deliveryAddress,
      contactDetails: draft.contactDetails,
      deliveryPlaced: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (productIds.length > 0) {
      userUpdate.purchasedProductIds = admin.firestore.FieldValue.arrayUnion(...productIds);
    }

    await db.collection("users").doc(cleanString(draft.uid)).set(
      userUpdate,
      { merge: true }
    );
  }

  return {
    placed: true,
    orderRef: effectiveOrderRef,
    orderId: orderDoc.id,
    reason: existingOrderRef ? "already-exists" : "created",
  };
}

module.exports = {
  upsertPaymentRecord,
  getPaymentRecord,
  findOrderByPaymentTxnId,
  createOrderFromPaymentSuccess,
};
