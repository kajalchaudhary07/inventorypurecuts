# Dashboard Scalability Deploy & Smoke Checklist

## 1) Deploy Firestore indexes

- Deploy `firestore.indexes.json` to ensure review/customer query shapes are indexed.
- Wait until all indexes show **Enabled** in Firebase Console.

## 2) Deploy Cloud Functions

Deploy updated functions including:
- `onOrderMetricsWrite`
- `getDashboardMetricsSnapshot`
- `rebuildOrderCounters`

## 3) Run one-time backfill (important)

Reason: existing historical orders must populate `users.ordersCount` and aggregate dashboard totals.

- Invoke callable function `rebuildOrderCounters` from an authenticated admin context.
- Verify response contains:
  - `ok: true`
  - `totalOrders`
  - `usersWithOrders`

## 4) Data validation checks

### Firestore document checks
- `aggregates/dashboard` exists and has:
  - `totalOrders`
  - `pendingOrders`
  - `totalRevenue`
  - `updatedAt`
- Sample users have:
  - `ordersCount` (number)
  - `hasPurchased` (boolean)

### Dashboard checks
- Dashboard loads without fallback errors.
- Revenue, pending orders, orders count are populated.

### Customers checks
- Customers list shows known ordering users.
- Pagination works across pages.

### Orders checks
- Orders list loads page 1 quickly.
- Load more works.

### Reviews checks
- Reviews list loads and can paginate.
- Approve/Delete still works.

### Chat checks
- Chat thread list loads and can load more.
- Message list loads recent messages and can load earlier messages.

### Notifications checks
- Notifications history paginates.
- Create/delete behavior unchanged.

## 5) Performance sanity checks

Track before/after for:
- p95 Dashboard load
- p95 Customers load (first page)
- Firestore reads per page view on Customers/Orders/Chat

Expected trend:
- Reads should be bounded by page size, not total collection size.

## 6) Rollback readiness

- Keep old fallback paths enabled during first production rollout window.
- If severe issues appear, temporarily disable new function usage and rely on fallback paths while investigating.
