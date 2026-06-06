const { HttpsError } = require("firebase-functions/v2/https");

function asCleanString(value) {
  return String(value ?? "").trim();
}

function ensureRequired(name, value) {
  const normalized = asCleanString(value);
  if (!normalized) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return normalized;
}

function normalizeAmount(value) {
  const raw = asCleanString(value);
  if (!raw) {
    throw new HttpsError("invalid-argument", "amount is required.");
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new HttpsError("invalid-argument", "amount must be a valid number greater than 0.");
  }

  return parsed.toFixed(2);
}

function normalizeUserId(value) {
  return asCleanString(value);
}

function validateGenerateHashInput(raw = {}) {
  const hashString = asCleanString(raw.hashString);
  const hashName = asCleanString(raw.hashName);

  if (hashString.length > 0 || hashName.length > 0) {
    if (!hashString) {
      throw new HttpsError("invalid-argument", "hashString is required when using SDK hash callback mode.");
    }
    return {
      mode: "sdk",
      hashString,
      hashName,
      userId: normalizeUserId(raw.userId),
      txnid: asCleanString(raw.txnid),
      amount: asCleanString(raw.amount),
      productinfo: asCleanString(raw.productinfo),
      firstname: asCleanString(raw.firstname),
      email: asCleanString(raw.email),
      phone: asCleanString(raw.phone),
      orderDraft: null,
    };
  }

  return {
    mode: "txn",
    txnid: ensureRequired("txnid", raw.txnid),
    amount: normalizeAmount(raw.amount),
    productinfo: ensureRequired("productinfo", raw.productinfo),
    firstname: ensureRequired("firstname", raw.firstname),
    email: ensureRequired("email", raw.email),
    phone: asCleanString(raw.phone),
    userId: normalizeUserId(raw.userId),
    orderDraft:
      raw.orderDraft && typeof raw.orderDraft === "object" && !Array.isArray(raw.orderDraft)
        ? raw.orderDraft
        : null,
  };
}

function validateVerifyPaymentInput(raw = {}) {
  const status = ensureRequired("status", raw.status).toLowerCase();
  const hashRaw = asCleanString(raw.hash).toLowerCase();
  const requiresHash = status === "success" || status === "failure";

  if (requiresHash && !hashRaw) {
    throw new HttpsError("invalid-argument", "hash is required for success/failure verification.");
  }

  const hasTxnFields =
    asCleanString(raw.productinfo).length > 0 &&
    asCleanString(raw.firstname).length > 0 &&
    asCleanString(raw.email).length > 0;

  return {
    hash: hashRaw,
    status,
    txnid: ensureRequired("txnid", raw.txnid),
    amount: normalizeAmount(raw.amount),
    productinfo: hasTxnFields
      ? ensureRequired("productinfo", raw.productinfo)
      : asCleanString(raw.productinfo),
    firstname: hasTxnFields
      ? ensureRequired("firstname", raw.firstname)
      : asCleanString(raw.firstname),
    email: hasTxnFields ? ensureRequired("email", raw.email) : asCleanString(raw.email),
    key: asCleanString(raw.key),
    additionalCharges: asCleanString(raw.additionalCharges),
    mihpayid: asCleanString(raw.mihpayid),
    mode: asCleanString(raw.mode),
    userId: normalizeUserId(raw.userId),
    udf1: asCleanString(raw.udf1),
    udf2: asCleanString(raw.udf2),
    udf3: asCleanString(raw.udf3),
    udf4: asCleanString(raw.udf4),
    udf5: asCleanString(raw.udf5),
  };
}

function validateSyncPaymentStatusInput(raw = {}) {
  return {
    txnid: ensureRequired("txnid", raw.txnid),
    userId: normalizeUserId(raw.userId),
  };
}

function validatePayuWebhookInput(raw = {}) {
  const status = ensureRequired("status", raw.status).toLowerCase();
  const txnid = ensureRequired("txnid", raw.txnid);

  const amountSource =
    raw.amount ?? raw.amt ?? raw.net_amount_debit ?? raw.netAmountDebit;
  const amount = normalizeAmount(amountSource);

  const productinfo = asCleanString(raw.productinfo || raw.productInfo);
  const firstname = asCleanString(raw.firstname || raw.firstName);
  const email = asCleanString(raw.email);

  return {
    status,
    txnid,
    amount,
    hash: asCleanString(raw.hash).toLowerCase(),
    productinfo,
    firstname,
    email,
    key: asCleanString(raw.key),
    additionalCharges: asCleanString(raw.additionalCharges),
    mihpayid: asCleanString(raw.mihpayid || raw.mihPayId),
    mode: asCleanString(raw.mode),
    udf1: asCleanString(raw.udf1),
    udf2: asCleanString(raw.udf2),
    udf3: asCleanString(raw.udf3),
    udf4: asCleanString(raw.udf4),
    udf5: asCleanString(raw.udf5),
    userId: normalizeUserId(raw.userId || raw.udf1),
  };
}

module.exports = {
  validateGenerateHashInput,
  validateVerifyPaymentInput,
  validateSyncPaymentStatusInput,
  validatePayuWebhookInput,
  normalizeAmount,
  asCleanString,
};
