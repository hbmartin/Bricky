# App Store Connect — Bricky Pro In-App Purchase Setup

This guide covers configuring Bricky's monetization in **App Store Connect**:
creating the one-time **Bricky Pro** purchase and retiring the old
subscription products.

## Background

Bricky Pro is a **single one-time (non-consumable) purchase — $4.99**. There is
no monthly or annual subscription. Cloud AI subject scanning is a hidden,
developer-only feature (unlocked via the in-app developer override) and is **not**
a purchasable product.

You **cannot convert** a subscription into a one-time purchase in App Store
Connect — they are different product types, each with their own permanent
product ID. So the migration is: **create a new Non-Consumable** and separately
**remove the old subscriptions from sale**.

### Product IDs

| Product | Type | Product ID | Status |
|---|---|---|---|
| Bricky Pro | Non-Consumable | `com.bricky.app.pro` | **Create this** |
| Bricky Pro Monthly | Auto-Renewable Subscription | `com.bricky.app.pro.monthly` | **Retire** |
| Bricky Pro Annual | Auto-Renewable Subscription | `com.bricky.app.pro.annual` | **Retire** |

The product ID must match `AppConfig.iapProProductId` in the app
(`Bricky/App/AppConfig.swift`).

> **Note:** the local `Bricky.storekit` file is only for Xcode/simulator
> testing — it does **not** sync to App Store Connect. These steps configure the
> real products. Keep the product IDs identical in both places.

## A. Create the new one-time purchase ($4.99)

1. Sign in to **App Store Connect → My Apps → Bricky**.
2. In the left sidebar (Monetization area) click **In-App Purchases** → **Manage**
   (or the **+** next to *In-App Purchases*).
3. Click **Create** / **+**.
4. Choose type **Non-Consumable** → **Create**.
5. Fill in:
   - **Reference Name:** `Bricky Pro` (internal only, not shown to users).
   - **Product ID:** `com.bricky.app.pro` — must match `AppConfig.iapProProductId`
     exactly. ⚠️ This is permanent and can never be reused once created.
6. **Availability:** leave all countries/regions on (or pick a subset).
7. **Price Schedule:** click **Add Pricing** → select the **USD $4.99** price
   point → confirm. Apple auto-fills equivalent prices worldwide.
8. **App Store Localization:** add at least one (English) entry:
   - **Display Name:** `Bricky Pro`
   - **Description:** e.g. "Unlock unlimited scans, the full build library,
     3D & STL export, iCloud sync, and more."
9. **Review Information:** upload a screenshot (a shot of the paywall is fine)
   and add review notes.
10. Click **Save**. Status becomes **Ready to Submit**.
11. **Attach it to a version for first review:** open your app **version** page
    (the iOS version you're submitting) → scroll to **In-App Purchases** → **+**
    → select `Bricky Pro`. First-time IAPs are reviewed alongside an app version.

## B. Retire the two old subscriptions

A subscription cannot be deleted once created, but you remove it from sale so no
one new can buy it.

1. App Store Connect → **Bricky** → **Subscriptions** (left sidebar).
2. Open the **Bricky Pro** subscription group.
3. Click the **Monthly** product (`com.bricky.app.pro.monthly`):
   - If status is **Ready to Submit / Developer Removed from Sale** (never
     released): set **Cleared for Sale = No** / **Remove from Sale** → Save.
   - If it was ever **Approved/Live**: open it → under **Availability / Pricing**
     choose **Remove from Sale**. Existing subscribers (if any) keep access until
     they cancel; no new sign-ups are allowed.
4. Repeat for the **Annual** product (`com.bricky.app.pro.annual`).
5. Optional: rename their Reference Names to `RETIRED – Bricky Pro Monthly/Annual`
   so they're obviously deprecated internally.
6. If the subscription group is now empty/unused, leave it — Apple does not allow
   deleting groups, and an empty retired group is harmless.

## C. Gotchas

- **Don't delete product IDs** expecting to reuse them — IDs are permanent and
  globally unique to your developer account.
- **No real subscribers?** If the app was never live (or these were never
  approved), retiring is instant and clean. If there *were* live subscribers,
  "Remove from Sale" is the correct move — never try to mass-refund or cancel them.
- **The new IAP must ship with a build** that references `com.bricky.app.pro`
  (the app already does). In **Sandbox**, test the purchase **and** *Restore
  Purchases* before submitting.
- **Tax/Banking:** if you've never sold a paid item, confirm **Agreements, Tax,
  and Banking** shows the **Paid Apps agreement = Active**. Otherwise IAPs won't
  load — StoreKit returns no products and the paywall shows "Plans are
  unavailable."

## Related

- App code: `Bricky/App/AppConfig.swift` (`iapProProductId`),
  `Bricky/Services/SubscriptionManager.swift` (entitlement logic),
  `Bricky/Views/PaywallView.swift` (paywall UI).
- Local testing config: `Bricky.storekit`.
- Cloud AI (developer-only) proxy: `services/recognition-proxy/`.
