# PayU CheckoutPro Integration (PureCuts)

This document covers the production-safe PayU setup for Flutter + Firebase Functions.

## Architecture

- Frontend: Flutter (`payu_checkoutpro_flutter`)
- Backend: Firebase Functions with Express (`paymentApi`)
- Database: Firestore (`payments/{txnid}`)
- Gateway: PayU CheckoutPro (UPI, Cards, NetBanking, Wallets in one UI)

## Security model

1. **SALT stays backend-only** (never shipped in Flutter app).
2. Flutter calls backend `/generate-hash` and `/verify-payment`.
3. Backend verifies hash with SHA-512 before writing `success`.
4. UI trusts Firestore payment document updates (backend truth), not raw client callback.

## Backend endpoints

### `POST /generate-hash`

Input (minimum):
- `txnid`, `amount`, `productinfo`, `firstname`, `email`

Hash format:

`key|txnid|amount|productinfo|firstname|email|||||||||||salt`

Output:
- `hash`, `txnid`, `key`, `environment`

### `POST /verify-payment`

Input:
- PayU callback payload (`status`, `hash`, `txnid`, `amount`, etc.)

Behavior:
- Recomputes reverse hash in backend
- Validates authenticity
- Writes to Firestore `payments/{txnid}`:
  - `status` (`success`/`failure`/`cancelled`)
  - `amount`
  - `userId`
  - `timestamp`
  - `hashVerified`

## Firestore structure

Collection: `payments`

Document ID: `{txnid}`

Suggested fields:
- `txnid` (string)
- `userId` (string)
- `amount` (string)
- `status` (string)
- `payuStatus` (string)
- `hashVerified` (bool)
- `mihpayid` (string)
- `mode` (string)
- `timestamp` (server timestamp)
- `updatedAt` (server timestamp)

## Test credentials (mandatory)

Get test credentials from:

**PayU Dashboard → Test Credentials**

Required:
- Test Key
- Test Salt

Do not hardcode real credentials in source code.

## Test mode configuration

Use:
- `environment = "0"` in Flutter payment params
- `PAYU_ENV=0` in backend env/secrets

## Test data and scenarios

### Card test
- Dummy card: `4111111111111111`

### UPI test
- Use CheckoutPro UPI option (GPay/PhonePe/Paytm UPI style routes)
- Simulate approve/decline from test intent flow and verify Firestore status transitions.

### Mandatory scenarios
1. Payment success
2. Payment failure
3. User cancellation
4. Invalid/tampered hash
5. Hash API/network timeout
6. Duplicate callback/idempotent update for same `txnid`

## Flutter integration notes

- Service: `lib/core/services/payu_payment_service.dart`
- Example screen: `lib/features/orders/payu_payment_screen.dart`
- Required payment params include:
  - `key`, `transactionId`, `amount`, `productInfo`, `firstName`, `email`, `phone`
  - `android_surl`, `android_furl`, `environment`

CheckoutPro automatically shows UPI, Cards, NetBanking, and Wallets.

## Common mistakes to avoid

1. Putting `PAYU_SALT` in Flutter code.
2. Trusting `onPaymentSuccess` callback directly without backend verification.
3. Wrong hash field ordering (causes invalid hash).
4. Amount formatting mismatch (`1` vs `1.00`) between hash generation and verify.
5. Marking order paid before backend writes verified status.
6. Missing idempotency guard for repeated callbacks.

## Production cutover checklist

1. Replace test key/salt with production key/salt in secret manager only.
2. Switch env from `"0"` to `"1"` through config.
3. Keep backend verification mandatory.
4. Monitor hash mismatch logs and payment failure spikes.
