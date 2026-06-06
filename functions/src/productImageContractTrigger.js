const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();
const { FieldValue } = admin.firestore;
const IMAGE_CONTRACT_VERSION = "v1";

function cleanText(value) {
  return String(value ?? "").trim();
}

function firstNonEmpty(...values) {
  for (const value of values) {
    const text = cleanText(value);
    if (text) return text;
  }
  return "";
}

function toImageArray(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((item) => cleanText(item))
    .filter((item) => item.length > 0);
}

function uniqueOrdered(values) {
  const seen = new Set();
  const out = [];
  for (const value of values) {
    const text = cleanText(value);
    if (!text || seen.has(text)) continue;
    seen.add(text);
    out.push(text);
  }
  return out;
}

function normalizeProductImageContract(data = {}) {
  const images = toImageArray(data.images);
  const additionalImages = toImageArray(data.additionalImages);

  const thumbnailUrl = firstNonEmpty(
    data.thumbnailUrl,
    data.thumbnail,
    data.thumb,
    data.imageThumb,
    data.smallImage,
    data.image,
    data.imageUrl,
    images[0],
    additionalImages[0]
  );

  const fullImageUrl = firstNonEmpty(
    data.fullImageUrl,
    data.fullImage,
    data.largeImage,
    data.imageUrl,
    data.image,
    images[0],
    additionalImages[0],
    thumbnailUrl
  );

  const listImage = firstNonEmpty(thumbnailUrl, fullImageUrl);

  const nextImages = uniqueOrdered([
    fullImageUrl,
    ...images,
    ...additionalImages,
    thumbnailUrl,
  ]);

  return {
    image: listImage,
    imageUrl: firstNonEmpty(fullImageUrl, listImage),
    thumbnailUrl,
    thumbnail: thumbnailUrl,
    thumb: thumbnailUrl,
    fullImageUrl,
    images: nextImages,
    imageContractVersion: IMAGE_CONTRACT_VERSION,
    imageContractUpdatedAt: FieldValue.serverTimestamp(),
  };
}

function shallowEqualProductImageFields(current = {}, next = {}) {
  const keys = [
    "image",
    "imageUrl",
    "thumbnailUrl",
    "thumbnail",
    "thumb",
    "fullImageUrl",
    "imageContractVersion",
  ];

  for (const key of keys) {
    if (cleanText(current[key]) !== cleanText(next[key])) {
      return false;
    }
  }

  const currentImages = toImageArray(current.images);
  const nextImages = toImageArray(next.images);
  if (currentImages.length !== nextImages.length) return false;
  for (let i = 0; i < currentImages.length; i += 1) {
    if (currentImages[i] !== nextImages[i]) return false;
  }

  return true;
}

function assertAdminCaller(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const claims = request.auth.token || {};
  if (claims.admin !== true && claims.superAdmin !== true) {
    throw new HttpsError(
      "permission-denied",
      "Only admins can trigger product image backfill."
    );
  }
}

exports.onProductImageContractWrite = onDocumentWritten(
  "products/{productId}",
  async (event) => {
    const afterData = event.data?.after?.data() || null;
    if (!afterData) return;

    const productId = cleanText(event.params?.productId);
    const normalized = normalizeProductImageContract(afterData);

    if (shallowEqualProductImageFields(afterData, normalized)) {
      return;
    }

    await event.data.after.ref.set(normalized, { merge: true });
    logger.info("[ProductImageContract] Normalized product image fields", {
      productId,
      contractVersion: IMAGE_CONTRACT_VERSION,
    });
  }
);

exports.backfillProductImageContract = onCall(async (request) => {
  assertAdminCaller(request);

  const rawLimit = Number(request.data?.limit || 500);
  const limit = Number.isFinite(rawLimit)
    ? Math.max(1, Math.min(2000, Math.floor(rawLimit)))
    : 500;
  const dryRun = request.data?.dryRun === true;

  const snap = await db
    .collection("products")
    .orderBy(admin.firestore.FieldPath.documentId())
    .limit(limit)
    .get();

  let scanned = 0;
  let updated = 0;

  for (const doc of snap.docs) {
    scanned += 1;
    const current = doc.data() || {};
    const normalized = normalizeProductImageContract(current);

    if (shallowEqualProductImageFields(current, normalized)) {
      continue;
    }

    updated += 1;
    if (!dryRun) {
      await doc.ref.set(normalized, { merge: true });
    }
  }

  logger.info("[ProductImageContract] Backfill complete", {
    scanned,
    updated,
    dryRun,
    limit,
    contractVersion: IMAGE_CONTRACT_VERSION,
  });

  return {
    ok: true,
    dryRun,
    scanned,
    updated,
    limit,
    contractVersion: IMAGE_CONTRACT_VERSION,
  };
});
