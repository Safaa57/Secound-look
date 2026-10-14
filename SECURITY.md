# Second Look security

Second Look is built so that there is very little to steal, and what exists is locked down.
This file lists every protection, what it defends against, and what is still left to do before a public launch.

## 1. Very little to steal from a server

| Protection | Defends against |
|---|---|
| All SMS, call and number checks run on the phone (or in the laptop's browser). Message text, callers' numbers and contacts are **never** sent anywhere. | Server breaches, data leaks, insider access |
| The only network use is user-started: **Deep check** sends just the link the user chose (max 5, never the message around it), and the optional rewarded ad and Plus purchase talk to Google/Apple. The server stores only a random install id, a daily counter and Plus status: no names, phone numbers, emails or links. | Profiling, data leaks from the server |
| HTTPS only: Android blocks cleartext traffic (`usesCleartextTraffic=false`), iOS App Transport Security is on, and the app ignores a server address that isn't `https://`. | Interception on public Wi-Fi |
| Ad and Plus credits are granted **only by the server**: rewarded ads use AdMob **server-side verification** (ECDSA signatures checked against Google's keys, each reward accepted once), and subscriptions are verified with the Google Play Developer API / App Store Server API. A hacked app can't give itself free checks or Plus. | Reward fraud, fake purchase receipts, replay attacks |
| The server rate-limits each IP (30 requests/min), caps each request, and refunds a check if the online lookup fails. | Abuse, denial of service |
| Only official packages from the Dart/Flutter teams and Google (`http`, `google_mobile_ads`, `in_app_purchase`, `image_picker`). Android also uses Google's libphonenumber and ML Kit (text recognition, barcode scanning); iOS uses Apple frameworks (including Vision). The laptop build contains no ad or billing code. | Supply-chain attacks through dependencies |
| Ads are optional, shown only when the user taps "Watch a short ad", rated **G** (family-safe), non-personalised, and gambling, loans, crypto, dating and get-rich-quick categories are blocked in AdMob. Ads never appear on a scam warning or the "Being scammed?" screen. | Scam ads inside a scam-protection app |
| Contacts, SMS inbox and call log are never read. SMS Shield receives only new incoming SMS, and only while it's ON. | Over-collection, permission abuse |
| **Payment screenshots and QR codes are read on the phone**: Google ML Kit with bundled models on Android, Apple's Vision framework on iPhone. The image, its text and its QR codes are never uploaded. No photo or storage permission: Android uses the system Photo Picker (or the one image another app shares), iPhone asks only when you choose a photo or open the camera. ML Kit itself sends Google basic SDK diagnostics (device/app info, performance, error codes), never image content. | Leaking payment details, bank names, UPI ids and amounts |

## 2. Data on the phone

| Protection | Defends against |
|---|---|
| Alerts, marked numbers and the trusted contact are encrypted with **AES-256-GCM**. The key is created in the **Android Keystore** (hardware-backed on most phones) or the **iOS Keychain** (this device only), so it can't be copied off the phone. If the encrypted data is changed, it simply fails to open. | Phone theft, forensic copying, malware reading app files, tampering with stored data |
| Backups are switched off: `allowBackup=false`, plus data-extraction rules that exclude everything from cloud backup and phone-to-phone transfer. | Data leaking through Google backups or device transfer |
| **Delete all my data** wipes everything and destroys the encryption key. | Leftover data |
| Optional **App lock** with fingerprint, face or the phone PIN, through the system's own prompt. It re-locks after 30 seconds in the background. | Someone else picking up the phone |

## 3. Against scammers watching the screen

| Protection | Defends against |
|---|---|
| Android: **screen protection** (`FLAG_SECURE`) is ON by default. Screenshots, screen recording and screen-sharing apps (AnyDesk, TeamViewer, QuickSupport) see a black screen. | Remote-access scams that read the screen |
| iPhone: a **live warning** appears the moment the screen starts being recorded or shared. | The same scam on iPhone, where apps can't block it |
| iPhone: the app is blurred in the app switcher. Android: `FLAG_SECURE` hides it from Recents. | Shoulder-surfing, screenshots of Recents |
| Android **tapjacking guard**: taps are ignored while another app draws an invisible overlay on top. | Overlay attacks that trick you into switching shields off |

## 4. Against tampering and reverse engineering

| Protection | Defends against |
|---|---|
| Release builds are **shrunk and obfuscated**: R8 for Java code (classes repackaged, logs stripped) and `--obfuscate` for Dart. | Reverse engineering, finding code to patch |
| **Rules integrity**: the SHA-256 of the scam rules and number data is built into the app. If someone edits them in a repackaged copy, the engine refuses to run and the app tells the user to reinstall. | Fake copies that whitelist scam links |
| **Signature check**: when you set your release key's fingerprint (`SECONDLOOK_CERT_SHA256`), a re-signed copy of the app refuses to run. | Repackaged or trojanised copies on third-party sites |
| Detection of **debuggers**, **hooking tools** (Frida, Xposed, LSPosed, Substrate) and **root/jailbreak**, shown in Settings › Security check and as a warning on the Home screen. The app warns rather than blocks on root, because rooted phones also belong to honest users. | Runtime manipulation |

## 5. Against malicious input

| Protection | Defends against |
|---|---|
| Every text, link, sender and number is capped (10,000 / 2,048 / 64 / 40 characters) before it's checked. | Giant inputs that freeze the phone |
| All scam patterns use bounded repetition, and the link finder was hardened after fuzzing. The worst 10,000-character input now takes about 10 ms, down from 700 ms. | Regex denial-of-service (ReDoS) |
| Links can only open a fixed allowlist of `https` sites (a web search, Google's Web Risk advisory page, antiphishing.org, cybercrime.gov.in, sancharsaathi.gov.in). Phone numbers are stripped to digits and `+`, notification ids are validated, and shared text is capped. | Intent injection, opening `file:`/`intent:` links, crafted notifications |
| Screenshot reading only opens files whose **real path** (symlinks and `../` resolved) is inside the app's own cache/files folders (iPhone: tmp, Caches, Documents). Any other path is refused. Images are downscaled to 2,500 px before reading, and the result is capped (10,000 characters of text, 5 QR codes of 2,048 characters). | Reading other files through the image reader, decompression bombs, out-of-memory crashes |
| **Share a screenshot** (Android): only `content://` images from other apps are accepted (never our own providers), the type reported by the sending app's provider must be `image/*`, the copy stops at **15 MB**, the file must really decode as an image, and it's copied into a private cache folder that keeps only the latest one. All of this runs off the UI thread. | Malicious share intents, huge or fake "images", reading our own private files |
| The SMS receiver only accepts broadcasts from the system (`BROADCAST_SMS`), and call screening only from the system (`BIND_SCREENING_SERVICE`). Every PendingIntent is immutable. | Other apps faking SMS or calls into Second Look |
| A failure inside the checker never crashes the phone's SMS or calling, and errors show no internal details. | Crashes, information leaks |

## Before a public launch

1. **Release signing:** create an upload key and turn on Play App Signing. Put the SHA-256 of the **app signing** certificate (Play Console › App integrity) in `SECONDLOOK_CERT_SHA256` when running `tool/setup.sh`.
2. **Play Integrity API (Android) and App Attest (iOS):** add these to the deep-check server before a large launch. They prove a request comes from your genuine app on a genuine phone, so scripts can't burn your Web Risk quota with made-up install ids.
3. **Server:** run it behind HTTPS only, keep `SL_DEV_PLUS` unset in production, store the Google service-account JSON and Apple keys as secrets, and back up the database.
4. **Independent penetration test:** have an outside security firm test against OWASP MASVS before launch.
5. **Keep the build pipeline safe:** protect the GitHub account with 2FA, pin GitHub Actions to commit SHAs, and keep the signing key out of the repository (use GitHub encrypted secrets).
6. **Updates:** ship rule updates only inside signed app releases. Never download rules at runtime unless they're signed and verified.
7. **Vulnerability reporting:** publish a security contact (for example `security@<your-domain>`) and a `security.txt`.

No app can be made unhackable. These layers make attacks expensive and keep users safe even if one layer fails.
