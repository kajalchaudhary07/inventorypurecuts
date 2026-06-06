const { onSupportMessageCreated } = require("./supportBot");
const { setAdminClaims, listAdminsFromAuth } = require("./adminClaims");
const { sendNotification } = require("./notifications/notificationService");
const { registerFcmToken } = require("./notifications/tokenService");
const { onOrderPlacedNotification } = require("./notifications/orderPlacedTrigger");
const { onVerificationRequestCreated } = require("./verificationRequestsTrigger");
const {
	onProductImageContractWrite,
	backfillProductImageContract,
} = require("./productImageContractTrigger");
const { reconcileSuccessfulPayments } = require("./payment/paymentReconciler");
const {
	onOrderMetricsWrite,
	getDashboardMetricsSnapshot,
	rebuildOrderCounters,
} = require("./dashboardMetrics");
const { paymentApi } = require("./payment/paymentHandler");
const { createCodOrder } = require("./codOrder");

exports.onSupportMessageCreated = onSupportMessageCreated;
exports.setAdminClaims = setAdminClaims;
exports.listAdminsFromAuth = listAdminsFromAuth;
exports.sendNotification = sendNotification;
exports.registerFcmToken = registerFcmToken;
exports.onOrderPlacedNotification = onOrderPlacedNotification;
exports.onVerificationRequestCreated = onVerificationRequestCreated;
exports.onProductImageContractWrite = onProductImageContractWrite;
exports.backfillProductImageContract = backfillProductImageContract;
exports.onOrderMetricsWrite = onOrderMetricsWrite;
exports.getDashboardMetricsSnapshot = getDashboardMetricsSnapshot;
exports.rebuildOrderCounters = rebuildOrderCounters;
exports.paymentApi = paymentApi;
exports.reconcileSuccessfulPayments = reconcileSuccessfulPayments;
exports.createCodOrder = createCodOrder;
