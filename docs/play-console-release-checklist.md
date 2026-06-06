# Play Console Release Checklist (PureCuts)

Use this checklist before every Android release.

## 1) One-time signing setup

- [ ] Generate upload keystore (`.jks`) and save it securely.
- [ ] Store these safely (password manager + backup):
  - [ ] keystore password (`storePassword`)
  - [ ] key alias (`keyAlias`)
  - [ ] key password (`keyPassword`)
- [ ] Create `android/key.properties` from `android/key.properties.example`.
- [ ] Confirm `android/key.properties` and keystore are not committed.

## 2) Configure app version for release

- [ ] Update `pubspec.yaml` version: `x.y.z+buildNumber`
- [ ] Ensure `buildNumber` is greater than previous Play upload.

## 3) Build release bundle

- [ ] Build Android App Bundle (`.aab`) from Flutter.
- [ ] Confirm output generated successfully.

Expected output path:

- `build/app/outputs/bundle/release/app-release.aab`

## 4) Play Console preparation

- [ ] App content forms completed (privacy, data safety, ads, etc.).
- [ ] Store listing assets/text are complete.
- [ ] Pricing and countries configured.

## 5) Internal testing first

- [ ] Create Internal testing release.
- [ ] Upload `app-release.aab`.
- [ ] Add tester accounts.
- [ ] Install app via testing link.

## 6) Validate update flow

- [ ] Install previous version on a test device.
- [ ] Upload next build with incremented `buildNumber`.
- [ ] Confirm in-place app update works.

## 7) Production rollout

- [ ] Start staged rollout (recommended).
- [ ] Monitor crashes/ANRs and critical metrics.
- [ ] Expand rollout after validation.

## 8) Migration to another machine

You can publish updates from any machine if all of these are available:

- [ ] Same `.jks` upload keystore file
- [ ] Same `storePassword`
- [ ] Same `keyAlias`
- [ ] Same `keyPassword`

## 9) Emergency fallback

If upload key is lost and Play App Signing is enabled:

- [ ] Request upload key reset in Play Console.
