# Data handling

E Ink connects to the existing ESP32 E-Ink service. Clerk handles account authentication and stores its session using the device Keychain. The app asks Clerk for a current bearer token per API request; it does not save passwords or embed a server secret key.

Account details, manually entered source settings (including weather coordinates), layouts, device names and provider credentials are sent over HTTPS to the configured service. Provider keys and private calendar URLs are handled by the existing backend's credential endpoints; the app shows configured/masked status and keeps newly entered credentials in the current form only. Device delivery tokens are shown when issued and can be deliberately shared to provision your own display. Treat those as credentials.

Previews and device settings are held in memory. The app disables its API URL cache and cookie jar. Exporting a BMP writes a file only to the destination you select. The image can contain private calendar or other source content. No advertising or app analytics are added; authentication SDK behavior is covered by Clerk's own privacy manifest and policy.

Bluetooth access is requested only to find nearby compatible displays and send the chosen image. Scanning is bounded and transfers run in the foreground. The app does not request location permission, read contacts, or scan in the background.

This document describes implementation behavior; the service operator must supply their public privacy policy and accurate App Store privacy disclosures before publishing. Data storage, account deletion and retention on the service remain governed by its operator and Clerk configuration.
