# Install E Ink on an iPhone

The repository includes source and a macOS build workflow. A successful **iPhone build and tests** run produces **EInk-iPhone**, containing `EInk-unsigned.ipa` and its SHA-256 checksum. This is an unsigned app for a physical iPhone, not a simulator app and not directly installable.

## Configure the existing Clerk application

The app uses the same Clerk application as `esp32.scottlind.dk` and its public client key. Do not create a replacement Clerk app or change the web application's account data.

On 2 October 2026, the public Clerk configuration reported **Native API disabled**. Native sign-in will not work until this is enabled. The implementation does not change these account settings automatically.

Following [Clerk's iOS quickstart](https://clerk.com/docs/ios/getting-started/quickstart):

1. In the existing application's **Native applications** settings, enable the Native API if needed.
2. Register the iOS application using your Apple **App ID Prefix** and bundle identifier **`dk.scottlind.eink`**.
3. Ensure the configured native OAuth redirect is **`dk.scottlind.eink://callback`**. The app's URL scheme follows its bundle identifier.
4. Keep **`webcredentials:clerk.scottlind.dk`** in the app's Associated Domains capability. The corresponding Clerk domain must recognize the registered app.
5. The current instance also enables Apple sign-in. Keep the included **Sign in with Apple** entitlement and enable that capability for the Apple App ID/provisioning profile. Complete Clerk's [native Apple configuration](https://clerk.com/docs/ios/guides/configure/auth-strategies/sign-in-with-apple) for that App ID.
6. Confirm the existing Google/GitHub connections you want are enabled for this instance, then test the native flow.

The repository cannot infer your Apple App ID Prefix or provision a signing identity. These account settings must match the app you sign. If you change the bundle identifier, register that identifier with Clerk too. Native OAuth is handled by Clerk and the system authentication browser, never a web view collecting passwords.

## Run from Xcode

1. Install Xcode 26.3 or newer on a compatible Mac, then open `EInk.xcodeproj`.
2. Under **Signing & Capabilities**, choose your Apple development team. Use a provisioning profile that supports Associated Domains and Sign in with Apple.
3. Connect and trust your iPhone; enable Developer Mode if iOS prompts for it.
4. Select your iPhone and press Run.
5. Sign in, allow Bluetooth when asked, and choose a nearby powered-on display.

The checked-in simulator entitlement supports the Clerk Keychain without an Apple team; it is only used by simulator builds. Physical-device builds use your team's signing and `Config/EInk.entitlements`.

## Install a CI-built IPA

Download the **EInk-iPhone** artifact from a successful workflow run. Verify the SHA-256 checksum before signing. Re-sign the app with your own certificate and provisioning profile, preserving the bundle identifier, URL scheme and required entitlements, then install with your normal iOS distribution tooling. A free personal signing profile may not support Associated Domains; do not assume a generic re-signing tool will preserve Clerk's authentication capabilities.

For TestFlight or App Store distribution, archive/sign using an Apple Developer Program team, register the app in App Store Connect, complete privacy/store metadata, and upload using Xcode or your existing release tooling. This repository does not include Apple credentials, provisioning profiles or a claimed App Store listing.

## Physical-device acceptance

- Sign in with each enabled provider, cancel sign-in, relaunch with a saved session, sign out, and sign in to a second test account. Verify no prior account content remains.
- Load the account preview and a device override; save a source or layout change, confirm the web app sees it, and export a readable BMP.
- Deny Bluetooth permission, disable Bluetooth, scan with no display nearby, cancel a transfer, disconnect a display, and background the app during transfer. Confirm none reports a successful refresh.
- Push to bundled **250 × 122** firmware and visually confirm the display matches the selected device's rendered layout. Test compatible OpenDisplay hardware separately; a panel/configuration mismatch must refuse the transfer.
- Register a Wi-Fi device, issue its token, configure that token on the display, request refresh, and observe queued → applied after a real heartbeat. Test token rotation/revocation using a spare device.
- Exercise large text, VoiceOver, dark mode and a small iPhone screen. Test backend offline/expired-session errors without losing an unsaved form.

USB firmware installation remains a desktop workflow. If a display uses an older firmware protocol, update it from the web dashboard's Flash instructions first.
