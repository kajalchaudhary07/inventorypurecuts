const express = require("express");
const cors = require("cors");
const crypto = require("crypto");
const logger = require("firebase-functions/logger");
const { onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const {
  validateGenerateHashInput,
  validateVerifyPaymentInput,
  validateSyncPaymentStatusInput,
  validatePayuWebhookInput,
} = require("./paymentValidators");
const { upsertPaymentRecord, createOrderFromPaymentSuccess } = require("./paymentRepository");

const PAYU_KEY = defineSecret("PAYU_KEY");
const PAYU_SALT = defineSecret("PAYU_SALT");

function readSecretValue(secretParam) {
  try {
    return String(secretParam?.value?.() || "").trim();
  } catch (_) {
    return "";
  }
}

function firstNonEmptyFromEnv(varNames) {
  for (const varName of varNames) {
    const value = String(process.env[varName] || "").trim();
    if (value) return value;
  }
  return "";
}

function getRuntimeConfig() {
  const key =
    readSecretValue(PAYU_KEY) ||
    firstNonEmptyFromEnv(["PAYU_KEY", "PAYU_MERCHANT_KEY"]);
  const salt =
    readSecretValue(PAYU_SALT) ||
    firstNonEmptyFromEnv(["PAYU_SALT", "PAYU_MERCHANT_SALT"]);
  const environment =
    firstNonEmptyFromEnv(["PAYU_ENV", "PAYU_ENVIRONMENT"]) || "1";

  return {
    key,
    salt,
    environment,
  };
}

function sha512(value) {
  return crypto.createHash("sha512").update(value).digest("hex");
}

function resolvePayuStatusUrl(environment) {
  return String(environment || "1") === "0"
    ? "https://info.payu.in/merchant/postservice.php?form=2"
    : "https://test.payu.in/merchant/postservice?form=2";
}

function mapGatewayStatus(statusRaw) {
  const status = String(statusRaw || "").trim().toLowerCase();
  if (["success", "captured", "settled", "completed"].includes(status)) {
    return "success";
  }
  if (["failure", "failed", "dropped", "bounced", "cancelled", "canceled"].includes(status)) {
    return "failure";
  }
  return "initiated";
}

async function fetchPayuTransactionStatus({ key, salt, txnid, environment }) {
  const command = "verify_payment";
  const hash = sha512(`${key}|${command}|${txnid}|${salt}`);
  const body = new URLSearchParams({
    key,
    command,
    var1: txnid,
    hash,
  }).toString();

  const endpoint = resolvePayuStatusUrl(environment);
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });

  const text = await response.text();
  let parsed = {};
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    throw new HttpsError("internal", "Unable to parse PayU status response.");
  }

  const details = parsed?.transaction_details || parsed?.transactionDetails || {};
  const txn = details?.[txnid] || details?.[String(txnid)] || {};
  const payuStatus = String(txn?.status || txn?.unmappedstatus || "").trim().toLowerCase();
  const amount = String(txn?.amt || txn?.amount || "").trim();
  const mihpayid = String(txn?.mihpayid || txn?.payuMoneyId || "").trim();
  const mode = String(txn?.mode || "").trim();

  return {
    payuStatus,
    finalStatus: mapGatewayStatus(payuStatus),
    amount,
    mihpayid,
    mode,
  };
}

function timingSafeHashCompare(expectedHex, receivedHex) {
  const expected = Buffer.from(String(expectedHex || ""), "hex");
  const received = Buffer.from(String(receivedHex || ""), "hex");

  if (!expected.length || expected.length !== received.length) {
    return false;
  }

  return crypto.timingSafeEqual(expected, received);
}

function buildGenerateHashString({ key, txnid, amount, productinfo, firstname, email, salt }) {
  return `${key}|${txnid}|${amount}|${productinfo}|${firstname}|${email}|||||||||||${salt}`;
}

function buildVerifyHashString({
  key,
  status,
  amount,
  txnid,
  productinfo,
  firstname,
  email,
  salt,
  udf1,
  udf2,
  udf3,
  udf4,
  udf5,
  additionalCharges,
}) {
  const base = `${salt}|${status}|${udf5}|${udf4}|${udf3}|${udf2}|${udf1}||||||${email}|${firstname}|${productinfo}|${amount}|${txnid}|${key}`;
  if (additionalCharges) {
    return `${additionalCharges}|${base}`;
  }
  return base;
}

function toHttpError(error) {
  if (error instanceof HttpsError) {
    const statusCode = error.code === "invalid-argument" ? 400 : 401;
    return { statusCode, message: error.message };
  }
  return { statusCode: 500, message: "Internal server error" };
}

const app = express();
app.use(cors({ origin: true }));
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: false }));

app.get("/health", (_, res) => {
  res.status(200).json({ ok: true, service: "paymentApi" });
});

app.post("/generate-hash", async (req, res) => {
  try {
    const { key, salt, environment } = getRuntimeConfig();
    if (!key || !salt) {
      logger.error("[PayU][GenerateHash] Missing PAYU_KEY/PAYU_SALT configuration");
      return res.status(500).json({ ok: false, error: "PayU configuration missing" });
    }

    const payload = validateGenerateHashInput(req.body || {});

    const hashString = payload.mode === "sdk"
      ? `${payload.hashString}${salt}`
      : buildGenerateHashString({
          key,
          txnid: payload.txnid,
          amount: payload.amount,
          productinfo: payload.productinfo,
          firstname: payload.firstname,
          email: payload.email,
          salt,
        });

    const hash = sha512(hashString);

    if (payload.txnid) {
      await upsertPaymentRecord({
        txnid: payload.txnid,
        userId: payload.userId,
        amount: payload.amount || "0.00",
        status: "initiated",
        hashVerified: false,
        payuStatus: "initiated",
        mihpayid: "",
        mode: "",
        responseHashPrefix: "",
        orderDraft: payload.orderDraft,
      });
    }

    logger.info("[PayU][GenerateHash] Hash generated", {
      txnid: payload.txnid,
      amount: payload.amount,
      environment,
    });

    return res.status(200).json({
      ok: true,
      hash,
      hashName: payload.hashName || "payment_hash",
      key,
      environment,
      txnid: payload.txnid,
      amount: payload.amount,
    });
  } catch (error) {
    const { statusCode, message } = toHttpError(error);
    logger.error("[PayU][GenerateHash] Failed", {
      statusCode,
      message,
      error: String(error?.message || error),
    });
    return res.status(statusCode).json({ ok: false, error: message });
  }
});

app.post("/verify-payment", async (req, res) => {
  try {
    const { key, salt } = getRuntimeConfig();
    if (!key || !salt) {
      logger.error("[PayU][VerifyPayment] Missing PAYU_KEY/PAYU_SALT configuration");
      return res.status(500).json({ ok: false, error: "PayU configuration missing" });
    }

    const payload = validateVerifyPaymentInput(req.body || {});

    const isCancellation = payload.status === "cancelled" || payload.status === "user_cancelled";
    let hashVerified = false;
    let isGatewaySuccess = false;

    if (!isCancellation) {
      const effectiveKey = payload.key || key;
      const reverseHashString = buildVerifyHashString({
        key: effectiveKey,
        status: payload.status,
        amount: payload.amount,
        txnid: payload.txnid,
        productinfo: payload.productinfo,
        firstname: payload.firstname,
        email: payload.email,
        salt,
        udf1: payload.udf1,
        udf2: payload.udf2,
        udf3: payload.udf3,
        udf4: payload.udf4,
        udf5: payload.udf5,
        additionalCharges: payload.additionalCharges,
      });

      const expectedHash = sha512(reverseHashString);
      hashVerified = timingSafeHashCompare(expectedHash, payload.hash);
      isGatewaySuccess = payload.status === "success";
    }

    const finalStatus = isCancellation ? "cancelled" : (hashVerified && isGatewaySuccess ? "success" : "failure");

    await upsertPaymentRecord({
      txnid: payload.txnid,
      userId: payload.userId,
      amount: payload.amount,
      status: finalStatus,
      hashVerified,
      payuStatus: payload.status,
      mihpayid: payload.mihpayid,
      mode: payload.mode,
      responseHashPrefix: payload.hash.substring(0, 12),
    });

    let orderPlacement = { placed: false, reason: "not-applicable" };
    if (finalStatus === "success" && hashVerified) {
      orderPlacement = await createOrderFromPaymentSuccess(payload.txnid);
    }

    logger.info("[PayU][VerifyPayment] Verification completed", {
      txnid: payload.txnid,
      status: finalStatus,
      hashVerified,
      payuStatus: payload.status,
    });

    return res.status(200).json({
      ok: true,
      verified: hashVerified,
      status: finalStatus,
      txnid: payload.txnid,
      orderPlaced: orderPlacement.placed === true,
      orderRef: orderPlacement.orderRef || "",
      orderPlacementReason: orderPlacement.reason || "",
      reason: hashVerified
        ? isGatewaySuccess
          ? "verified-success"
          : "gateway-reported-failure"
        : (isCancellation ? "user-cancelled" : "hash-mismatch"),
    });
  } catch (error) {
    const { statusCode, message } = toHttpError(error);
    logger.error("[PayU][VerifyPayment] Failed", {
      statusCode,
      message,
      error: String(error?.message || error),
    });
    return res.status(statusCode).json({ ok: false, error: message });
  }
});

app.post("/sync-payment-status", async (req, res) => {
  try {
    const { key, salt, environment } = getRuntimeConfig();
    if (!key || !salt) {
      logger.error("[PayU][SyncPaymentStatus] Missing PAYU_KEY/PAYU_SALT configuration");
      return res.status(500).json({ ok: false, error: "PayU configuration missing" });
    }

    const payload = validateSyncPaymentStatusInput(req.body || {});
    const gateway = await fetchPayuTransactionStatus({
      key,
      salt,
      txnid: payload.txnid,
      environment,
    });

    const hashVerified = gateway.finalStatus === "success";

    await upsertPaymentRecord({
      txnid: payload.txnid,
      userId: payload.userId,
      amount: gateway.amount || "0.00",
      status: gateway.finalStatus,
      hashVerified,
      payuStatus: gateway.payuStatus || "unknown",
      mihpayid: gateway.mihpayid,
      mode: gateway.mode,
      responseHashPrefix: "",
    });

    let orderPlacement = { placed: false, reason: "not-applicable" };
    if (gateway.finalStatus === "success") {
      orderPlacement = await createOrderFromPaymentSuccess(payload.txnid);
    }

    logger.info("[PayU][SyncPaymentStatus] Sync completed", {
      txnid: payload.txnid,
      status: gateway.finalStatus,
      payuStatus: gateway.payuStatus,
      environment,
    });

    return res.status(200).json({
      ok: true,
      txnid: payload.txnid,
      status: gateway.finalStatus,
      payuStatus: gateway.payuStatus,
      amount: gateway.amount,
      verified: hashVerified,
      orderPlaced: orderPlacement.placed === true,
      orderRef: orderPlacement.orderRef || "",
      orderPlacementReason: orderPlacement.reason || "",
    });
  } catch (error) {
    const { statusCode, message } = toHttpError(error);
    logger.error("[PayU][SyncPaymentStatus] Failed", {
      statusCode,
      message,
      error: String(error?.message || error),
    });
    return res.status(statusCode).json({ ok: false, error: message });
  }
});

app.post("/payu-webhook", async (req, res) => {
  try {
    const { key, salt, environment } = getRuntimeConfig();
    if (!key || !salt) {
      logger.error("[PayU][Webhook] Missing PAYU_KEY/PAYU_SALT configuration");
      return res.status(200).json({ ok: false, accepted: false, error: "PayU configuration missing" });
    }

    const payload = validatePayuWebhookInput(req.body || {});

    const effectiveKey = payload.key || key;
    let payuStatus = payload.status;
    let finalStatus = mapGatewayStatus(payload.status);
    let amount = payload.amount;
    let mihpayid = payload.mihpayid;
    let mode = payload.mode;

    let hashVerified = false;
    const hasVerificationFields =
      payload.hash && payload.productinfo && payload.firstname && payload.email;

    if (hasVerificationFields) {
      const reverseHashString = buildVerifyHashString({
        key: effectiveKey,
        status: payload.status,
        amount: payload.amount,
        txnid: payload.txnid,
        productinfo: payload.productinfo,
        firstname: payload.firstname,
        email: payload.email,
        salt,
        udf1: payload.udf1,
        udf2: payload.udf2,
        udf3: payload.udf3,
        udf4: payload.udf4,
        udf5: payload.udf5,
        additionalCharges: payload.additionalCharges,
      });
      const expectedHash = sha512(reverseHashString);
      hashVerified = timingSafeHashCompare(expectedHash, payload.hash);
    }

    if (finalStatus === "success" && !hashVerified) {
      const gateway = await fetchPayuTransactionStatus({
        key,
        salt,
        txnid: payload.txnid,
        environment,
      });
      payuStatus = gateway.payuStatus || payuStatus;
      finalStatus = gateway.finalStatus;
      amount = gateway.amount || amount;
      mihpayid = gateway.mihpayid || mihpayid;
      mode = gateway.mode || mode;
      hashVerified = gateway.finalStatus === "success";
    }

    await upsertPaymentRecord({
      txnid: payload.txnid,
      userId: payload.userId,
      amount,
      status: finalStatus,
      hashVerified,
      payuStatus,
      mihpayid,
      mode,
      responseHashPrefix: payload.hash ? payload.hash.substring(0, 12) : "",
    });

    let orderPlacement = { placed: false, reason: "not-applicable" };
    if (finalStatus === "success" && hashVerified) {
      orderPlacement = await createOrderFromPaymentSuccess(payload.txnid);
    }

    logger.info("[PayU][Webhook] Processed", {
      txnid: payload.txnid,
      payuStatus,
      finalStatus,
      hashVerified,
      orderPlaced: orderPlacement.placed === true,
      orderPlacementReason: orderPlacement.reason || "",
    });

    return res.status(200).json({
      ok: true,
      accepted: true,
      txnid: payload.txnid,
      status: finalStatus,
      verified: hashVerified,
      orderPlaced: orderPlacement.placed === true,
      orderRef: orderPlacement.orderRef || "",
      orderPlacementReason: orderPlacement.reason || "",
    });
  } catch (error) {
    logger.error("[PayU][Webhook] Failed", {
      message: String(error?.message || error),
      error: String(error),
    });
    return res.status(200).json({ ok: false, accepted: false });
  }
});

exports.paymentApi = onRequest(
  {
    region: "asia-south1",
    timeoutSeconds: 60,
    memory: "256MiB",
    secrets: [PAYU_KEY, PAYU_SALT],
  },
  app
);
