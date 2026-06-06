const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();

const db = admin.firestore();

function normalizeRole(value) {
  const role = String(value || "staff").trim();
  if (["admin", "superAdmin", "staff"].includes(role)) return role;
  return "staff";
}

exports.setAdminClaims = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const callerClaims = request.auth.token || {};
  if (callerClaims.superAdmin !== true) {
    throw new HttpsError("permission-denied", "Only super admins can manage admin claims.");
  }

  const payload = request.data || {};
  const email = String(payload.email || "").trim().toLowerCase();
  const uidInput = String(payload.uid || "").trim();
  const role = normalizeRole(payload.role);
  const active = payload.active !== false;

  if (!uidInput && !email) {
    throw new HttpsError("invalid-argument", "Provide either uid or email.");
  }

  let userRecord;
  if (uidInput) {
    try {
      userRecord = await admin.auth().getUser(uidInput);
    } catch (error) {
      if (!email) {
        throw new HttpsError("not-found", "Target auth user not found.", String(error?.message || error));
      }
    }
  }

  if (!userRecord) {
    try {
      userRecord = await admin.auth().getUserByEmail(email);
    } catch (error) {
      throw new HttpsError("not-found", "Target auth user not found.", String(error?.message || error));
    }
  }

  const nextAdmin = active && (role === "admin" || role === "superAdmin");
  const nextSuperAdmin = active && role === "superAdmin";
  const existingClaims = userRecord.customClaims || {};

  await admin.auth().setCustomUserClaims(userRecord.uid, {
    ...existingClaims,
    admin: nextAdmin,
    superAdmin: nextSuperAdmin,
  });

  const userRef = db.doc(`users/${userRecord.uid}`);
  await userRef.set(
    {
      uid: userRecord.uid,
      email: userRecord.email || email,
      role,
      active,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(payload.name !== undefined ? { name: String(payload.name || "").trim() } : {}),
      ...(payload.phone !== undefined ? { phone: String(payload.phone || "").trim() } : {}),
      ...(payload.avatar !== undefined ? { avatar: String(payload.avatar || "").trim() } : {}),
    },
    { merge: true }
  );

  const adminRef = db.doc(`admins/${userRecord.uid}`);
  await adminRef.set(
    {
      uid: userRecord.uid,
      email: userRecord.email || email,
      role,
      active,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(payload.name !== undefined ? { name: String(payload.name || "").trim() } : {}),
      ...(payload.phone !== undefined ? { phone: String(payload.phone || "").trim() } : {}),
      ...(payload.avatar !== undefined ? { avatar: String(payload.avatar || "").trim() } : {}),
    },
    { merge: true }
  );

  return {
    ok: true,
    uid: userRecord.uid,
    email: userRecord.email || email,
    claims: {
      admin: nextAdmin,
      superAdmin: nextSuperAdmin,
    },
  };
});

exports.listAdminsFromAuth = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const callerClaims = request.auth.token || {};
  if (callerClaims.admin !== true && callerClaims.superAdmin !== true) {
    throw new HttpsError("permission-denied", "Only admins can list admin users.");
  }

  const users = [];
  let pageToken;

  do {
    const result = await admin.auth().listUsers(1000, pageToken);

    for (const user of result.users) {
      const claims = user.customClaims || {};
      const isAdmin = claims.admin === true;
      const isSuperAdmin = claims.superAdmin === true;
      if (!isAdmin && !isSuperAdmin) continue;

      users.push({
        uid: user.uid,
        email: user.email || "",
        phone: user.phoneNumber || "",
        name: user.displayName || "",
        role: isSuperAdmin ? "superAdmin" : "admin",
        active: user.disabled !== true,
        avatar: user.photoURL || "",
        claims: {
          admin: isAdmin,
          superAdmin: isSuperAdmin,
        },
      });
    }

    pageToken = result.pageToken;
  } while (pageToken);

  return { ok: true, users };
});