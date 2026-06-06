const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();
const ORDER_SEQUENCE_START = 535;
const COUNTER_DOC_PATH = "meta/orderCounters";

function cleanString(value) {
  return String(value || "").trim();
}

function normalizeOrderRef(value) {
  const clean = cleanString(value);
  if (!clean) return "";
  return clean.startsWith("#") ? clean.slice(1).trim() : clean;
}

function parsePositiveInt(value, fallback = 0) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.floor(parsed);
}

function normalizePaymentMethod(value) {
  const clean = cleanString(value);
  return clean || "Cash on Delivery";
}

function buildOrderRef(sequence, now = new Date()) {
  const ymd = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`;
  return `PC-${ymd}-${String(sequence).padStart(6, "0")}`;
}

function buildEditOrderDocId(sourceKey) {
  const safe = cleanString(sourceKey).replace(/[^a-zA-Z0-9_-]/g, "_");
  return `edit_${safe || "unknown"}`;
}

function parseOrderSeqFromRef(orderRef) {
  const normalized = normalizeOrderRef(orderRef);
  const match = normalized.match(/-(\d+)$/);
  if (!match) return 0;
  return parsePositiveInt(match[1], 0);
}

function normalizeItems(rawItems = [], orderRef = "") {
  const list = Array.isArray(rawItems) ? rawItems : [];
  let totalItems = 0;

  const items = list
    .filter((item) => item && typeof item === "object" && !Array.isArray(item))
    .map((item, index) => {
      const quantity = parsePositiveInt(item.quantity ?? item.qty ?? 1, 1);
      totalItems += quantity;
      const productId = cleanString(item.productId || item.id);
      return {
        ...item,
        id: productId,
        productId,
        quantity,
        orderId: orderRef,
        orderItemId: `${orderRef}-I${String(index + 1).padStart(2, "0")}`,
      };
    })
    .filter((item) => cleanString(item.productId));

  const productIds = Array.from(
    new Set(items.map((item) => cleanString(item.productId)).filter(Boolean))
  );

  return { items, productIds, totalItems };
}

function normalizeAddress(raw = {}, userProfile = {}) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    ...source,
    line1: cleanString(source.line1),
    line2: cleanString(source.line2),
    landmark: cleanString(source.landmark),
    city: cleanString(source.city),
    state: cleanString(source.state),
    pincode: cleanString(source.pincode || source.postalCode || userProfile.pincode),
    country: cleanString(source.country || userProfile.country || "India"),
    mapLink: cleanString(source.mapLink),
  };
}

function normalizeContact(raw = {}, userProfile = {}) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    ...source,
    receiverName: cleanString(source.receiverName || userProfile.name || userProfile.ownerName),
    phone: cleanString(source.phone || userProfile.phone || userProfile.mobile),
  };
}

exports.createCodOrder = onCall(async (request) => {
  try {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication is required.");
    }

    const payload = request.data || {};
    const authUid = cleanString(request.auth.uid);
    const uid = cleanString(payload.uid || authUid) || authUid;
    if (!uid) {
      throw new HttpsError("invalid-argument", "uid is required.");
    }

    if (uid !== authUid) {
      console.warn("[createCodOrder] Payload UID mismatch. Using auth UID.", {
        payloadUid: uid,
        authUid,
      });
    }

    const total = parsePositiveInt(payload.total, 0);
    const userProfile = payload.userProfile && typeof payload.userProfile === "object" ? payload.userProfile : {};
    const deliveryAddress = normalizeAddress(payload.deliveryAddress, userProfile);
    const contactDetails = normalizeContact(payload.contactDetails, userProfile);
    const customerName = cleanString(
      userProfile.name || userProfile.ownerName || contactDetails.receiverName
    );
    const customerEmail = cleanString(userProfile.email);
    const customerPhone = cleanString(contactDetails.phone || userProfile.phone || userProfile.mobile);
    const editMetaRaw = payload.editMeta && typeof payload.editMeta === "object" ? payload.editMeta : null;
    const editMeta = editMetaRaw
      ? {
          isEditOrder: editMetaRaw.isEditOrder === true,
          sourceOrderDocumentId: cleanString(editMetaRaw.sourceOrderDocumentId || editMetaRaw.sourceOrderId),
          sourceOrderId: cleanString(editMetaRaw.sourceOrderId || editMetaRaw.sourceOrderDocumentId),
          sourceOrderRef: cleanString(editMetaRaw.sourceOrderRef),
          windowHours: parsePositiveInt(editMetaRaw.windowHours),
          lockedQuantities:
            editMetaRaw.lockedQuantities && typeof editMetaRaw.lockedQuantities === "object"
              ? editMetaRaw.lockedQuantities
              : {},
          originalCreatedAt: cleanString(editMetaRaw.originalCreatedAt),
          originalTotalAmount: parsePositiveInt(editMetaRaw.originalTotalAmount),
          originalItemCount: parsePositiveInt(editMetaRaw.originalItemCount),
          originalPaymentMethod: cleanString(editMetaRaw.originalPaymentMethod),
        }
      : null;

    const now = admin.firestore.FieldValue.serverTimestamp();
    const counterRef = db.doc(COUNTER_DOC_PATH);
    const isEditOrder = Boolean(editMeta && editMeta.isEditOrder === true);
    const editSourceKey = cleanString(
      editMeta?.sourceOrderDocumentId || editMeta?.sourceOrderId || editMeta?.sourceOrderRef
    );
    const useEditFlow = isEditOrder && editSourceKey.length > 0;
    const orderDocRef = useEditFlow
      ? db.collection("orders").doc(buildEditOrderDocId(editSourceKey))
      : db.collection("orders").doc();

    let createdOrderRef = "";
    let createdSeq = ORDER_SEQUENCE_START;

    await db.runTransaction(async (tx) => {
    const currentSeq = useEditFlow
      ? 0
      : (() => {
          const fallback = ORDER_SEQUENCE_START - 1;
          return fallback;
        })();

    let resolvedCurrentSeq = currentSeq;
    if (!useEditFlow) {
      const counterSnap = await tx.get(counterRef);
      resolvedCurrentSeq = counterSnap.exists
        ? parsePositiveInt(counterSnap.data()?.globalSeq, ORDER_SEQUENCE_START - 1)
        : ORDER_SEQUENCE_START - 1;
    }

    const nextSeq = useEditFlow
      ? parseOrderSeqFromRef(editMeta?.sourceOrderRef)
      : Math.max(resolvedCurrentSeq + 1, ORDER_SEQUENCE_START);
    const nextOrderRef = buildOrderRef(nextSeq || ORDER_SEQUENCE_START);
    const editOrderRef = useEditFlow ? normalizeOrderRef(editMeta.sourceOrderRef) : "";
    const effectiveOrderRef = editOrderRef || nextOrderRef;

    const { items, productIds, totalItems } = normalizeItems(payload.items, effectiveOrderRef);
    if (items.length === 0) {
      throw new HttpsError("invalid-argument", "At least one valid order item is required.");
    }

    const billDetails =
      payload.billDetails && typeof payload.billDetails === "object"
        ? payload.billDetails
        : {};

    const addressSummary = [
      cleanString(deliveryAddress.line1),
      cleanString(deliveryAddress.line2),
      cleanString(deliveryAddress.city),
      cleanString(deliveryAddress.state),
      cleanString(deliveryAddress.pincode),
    ]
      .filter(Boolean)
      .join(", ");

    const payloadToPersist = {
      orderId: effectiveOrderRef,
      orderRef: effectiveOrderRef,
      orderNumber: effectiveOrderRef,
      orderSeq: nextSeq,
      orderSeqSource: "cod_cloud_function",
      uid: authUid,
      userId: authUid,
      customerId: authUid,
      customerName,
      customerEmail,
      customerPhone,
      phone: customerPhone,
      deliveryAddress,
      address: addressSummary,
      contactDetails,
      paymentMethod: normalizePaymentMethod(payload.paymentMethod),
      paymentTxnId: "",
      billDetails,
      items,
      productIds,
      itemCount: items.length,
      itemsCount: items.length,
      totalItems,
      total,
      amount: total,
      totalAmount: total,
      grandTotal: total,
      deliveryPlaced: true,
      status: isEditOrder ? "edited" : "placed",
      orderStatus: isEditOrder ? "edited" : "placed",
      paymentStatus: "pending",
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
      createdAt: now,
      updatedAt: now,
    };

    tx.set(orderDocRef, payloadToPersist, { merge: useEditFlow });
    if (!useEditFlow) {
      tx.set(
        counterRef,
        {
          globalSeq: nextSeq,
          updatedAt: now,
          createdAt: now,
        },
        { merge: true }
      );
    }

    tx.set(
      db.collection("users").doc(authUid),
      {
        purchasedProductIds: admin.firestore.FieldValue.arrayUnion(...productIds),
        deliveryAddressDetails: deliveryAddress,
        contactDetails,
        deliveryDetails: {
          deliveryAddress,
          contactDetails,
          deliveryPlaced: true,
          lastOrderRef: effectiveOrderRef,
          updatedAt: now,
        },
        deliveryPlaced: true,
        updatedAt: now,
      },
      { merge: true }
    );

    createdOrderRef = effectiveOrderRef;
    createdSeq = nextSeq;
  });

  const sourceOrderDocumentId = cleanString(editMeta?.sourceOrderDocumentId || editMeta?.sourceOrderId);
  if (sourceOrderDocumentId && sourceOrderDocumentId !== orderDocRef.id) {
    await db.collection("orders").doc(sourceOrderDocumentId).set(
      {
        status: "edited",
        orderStatus: "edited",
        editedAt: now,
        editedByOrderId: createdOrderRef,
        editedByOrderDocumentId: orderDocRef.id,
        updatedAt: now,
      },
      { merge: true }
    );
  }

    return {
      ok: true,
      orderRef: createdOrderRef,
      orderId: orderDocRef.id,
      orderSeq: createdSeq,
    };
  } catch (error) {
    console.error("[createCodOrder] failed", {
      message: error?.message || String(error),
      code: error?.code || null,
      stack: error?.stack || null,
    });
    if (error instanceof HttpsError) {
      throw error;
    }
    throw new HttpsError("internal", error?.message || "COD order creation failed");
  }
});
