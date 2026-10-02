# E Ink for iPhone

A native SwiftUI companion to [ESP32 E-Ink Home Display](https://github.com/scottlinddk/ESP32-e-ink-system). Uses the same server, Clerk accounts, sources and saved layouts at **https://esp32.scottlind.dk**. Requires iOS 17 or newer.

The iPhone app lives separately because it has its own Xcode project, Bluetooth implementation and signing/release process. The existing backend and firmware remain authoritative; no duplicate database or web wrapper is included.

## What it does

- Preview the actual server-rendered monochrome image for your account or a registered device; export BMP to Files.
- Discover nearby bundled `EInk-` and OpenDisplay devices with native CoreBluetooth. Check the panel profile, send a fresh image, and wait for the panel's **refresh complete** response.
- Register, rename and remove devices. Inspect Wi-Fi delivery telemetry, request the next refresh, and create/rotate/revoke per-device delivery tokens.
- Edit account sources, source credentials, panel dimensions, rotation, refresh interval and widget positions. Edit per-device display overrides separately.
- Sign in with the existing Clerk account through Clerk's native authentication components; manage your account and sign out.

There is no demo backend or invented live data. Failed network requests and unconfirmed display updates remain visible errors. Bluetooth transfers keep the screen awake until completion, and stop on cancellation, sign-out, or backgrounding. Automatic Wi-Fi updates run on the display itself.

## Open and run

1. On a Mac with **Xcode 26.3 or newer**, open `EInk.xcodeproj` and select the **EInk** scheme.
2. Let Swift Package Manager resolve ClerkKit/ClerkKitUI **1.5.8**. Clerk is the only direct third-party dependency.
3. Run on an iPhone simulator to inspect the UI and run tests. Bluetooth requires a physical iPhone.
4. Follow [installation and authentication setup](docs/INSTALL.md) before running on your iPhone. Signing and registration with the existing Clerk application are deployment prerequisites.

The public Clerk client key is already configured from the deployed website. No secret key belongs in the app. To target another deployment, update `EInkServerURL`, `ClerkPublishableKey`, and the associated domain in `Config/`; use that deployment's native app registration.

**Sign-in setup remains required:** the existing Clerk instance reported Native API disabled on 2 October 2026. Enable it and register your Apple App ID Prefix + `dk.scottlind.eink` before using native sign-in. These account settings and iPhone signing cannot be validated by simulator tests.

## Build and tests

The checked-in project opens directly; no project generator installation is needed. After adding/removing files, regenerate it with Python:

```sh
python3 scripts/generate_project.py
python3 scripts/validate_project.py
xcodebuild test -project EInk.xcodeproj -scheme EInk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Choose an installed simulator from `xcrun simctl list devices available`. The **iPhone build and tests** GitHub Actions workflow selects one automatically, compiles the app, runs XCTest, attempts an optional welcome-screen capture and independently builds an unsigned physical-device IPA. Download **EInk-iPhone** from a successful run for the IPA, checksum, signing entitlements and installation notes. The IPA needs signing before it can be installed; it is not a TestFlight build.

Tests exercise mocked API responses, HTTPS/token boundaries, partial preference updates, JSON compatibility, preview identity/dimensions/encoding and both Bluetooth protocols. They do not sign in to production or contact real displays. The portable Python checks verify project/resource consistency only; compilation and XCTest run on macOS.

Validated on 2 October 2026: [run 37014281433](https://github.com/scottlinddk/ESP32-e-ink-iOS/actions/runs/37014281433) passed **21 tests with zero failures**, the simulator build and the unsigned arm64 iPhone build. The IPA's SHA-256 checksum and iOS 17 minimum deployment target were verified after download. The optional final screenshot step timed out; an earlier build's welcome screen was captured and visually inspected. Native sign-in and Bluetooth on physical hardware remain unverified pending the setup and acceptance steps below.

## Hardware and compatibility

The API/firmware contract is based on upstream commit [`3244623`](https://github.com/scottlinddk/ESP32-e-ink-system/commit/3244623cfa8c5aba0dcaa9bb294e73a668ae5b9b). The server must expose the current preview metadata headers and device display/delivery endpoints.

Bundled firmware service `c9c10001-7a6b-4c31-8a98-89e539e43805` supports padded rows, including **250 × 122**. Its writes are capped at 20 bytes (2-byte command + 18 pixels bytes). OpenDisplay service `0x2446` uses its existing configuration/ACK protocol and requires a byte-aligned monochrome width. Encrypted OpenDisplay configurations are rejected with an explanation. The app does not provision Wi-Fi credentials or flash firmware over Bluetooth.

USB flashing, advanced EV-provider credentials, layout libraries and schedules remain available in the web dashboard. Saving settings does not itself force a physical display refresh. A Wi-Fi refresh request is queued for the next device poll; it is only applied once the server reports the device's acknowledgement.

Before release, complete the [physical-device acceptance checklist](docs/INSTALL.md#physical-device-acceptance). Simulator tests cannot verify radio behavior, firmware execution or the actual e-ink panel. See [privacy](docs/PRIVACY.md) for data handling.
