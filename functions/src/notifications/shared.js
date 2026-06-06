const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

const TOPICS = {
  ALL_USERS: "all_users",
};

module.exports = {
  admin,
  db,
  TOPICS,
};
