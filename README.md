# Second Look for Android and iPhone

A scam shield for SMS, links and calls that works **entirely on the phone**. It tells you in plain words whether
something is a scam, why, and what to do next.

## How Second Look works

| | Second Look |
|---|---|
| How it knows | Never touches your contacts. Uses rules, number intelligence, community scam reports and your own reports |
| SMS | Checks each SMS on the device and explains the trick (fake KYC, UPI "receive money", digital arrest, fake courier, look-alike links) |
| Sender check | Verifies India's registered SMS sender IDs (e.g. `VM-SBIINB-T`): a "bank" SMS from a 10-digit mobile number is flagged as fake; the -P/-S/-T/-G suffix is checked against what the message claims |
| Caller type | **Person, business, telemarketer (140), bank/government service line (1600), helpline, possible bot (VoIP/premium), foreign, fake-looking number or reported scam**, plus state and network |
| Control | Every shield is **OFF until you switch it on**; the SMS receiver is physically disabled while off |
| Family | Optional trusted person: one tap sends them "can you check this with me?" (you send it, nothing automatic) |
| In a crisis | "Being scammed?" screen with the exact steps and one-tap 1930 |
| Account | None |
| Ads | Never on warnings. Only an optional ad you choose to watch for an extra deep check |

## Features

- **SMS Shield**: Android checks every incoming SMS in the background and shows a warning notification. iPhone sorts scam texts from unknown senders into Junk.
- **Call Shield**: Android shows who's calling while the phone rings (caller type, state, network, verdict) and can silence likely scam calls. iPhone blocks and labels numbers you report.
- **Check tab**: paste a link, a message (with its sender) or a number.
- **Share to Second Look** (Android): share any text from WhatsApp, Gmail or a browser to check it.
- **Alerts**: history kept only on the phone, with one-tap clear.
- **Report/Trust a number**: your personal block list, used by both shields.
- **Being scammed?** panic screen.
- **Deep check** (optional, online): checks a link against Google Web Risk and phishing blocklists. 3 free a day,
  1 more per optional rewarded ad, unlimited with **Plus**. Only the link is sent. See `app/docs/ADS_AND_PLUS.md`.
- **Laptop version**: the same app runs in any browser (Chrome, Edge, Safari) for checking links, messages and numbers.

## Project layout

```
mobile/
  app/                      Flutter app (UI in Dart)
    lib/                    screens, widgets, theme, native bridge
    android_overlay/        Android native code (Java): SMS receiver, call screening, notifications, permissions
    packages/secondlook_ios iOS plugin (Swift): runs the engine in JavaScriptCore, settings, call directory reload
    ios_extensions/         iOS Message Filter + Call Directory extensions (Swift)
    tool/setup.sh           one-time setup
    docs/                   iOS setup, Play Store permission declaration, privacy policy
  engine-java/              The engine for Android (Java port), plus tests proving it matches the JS engine
  shared/                   The engine bundle for iOS (same JS as the web app)
```

The scam rules live in one file (`rules.json` at the repo root). Run `./build.sh` after editing it, and every platform
(web, extension, Python, Android, iOS) gets the same rules.

## Build

Requirements: Flutter 3.22+, Android Studio (Android SDK 34+), and for iOS a Mac with Xcode 15+ and CocoaPods.

```bash
cd mobile/app
./tool/setup.sh          # creates android/ and ios/, copies native code and engine
flutter run              # Android phone (Android 10+)
flutter run -d chrome    # laptop (web)
```

Turn on Deep check and Plus by passing your server: `--dart-define=SL_API=https://your-server` (see `app/docs/ADS_AND_PLUS.md`).

iPhone: follow `docs/IOS_SETUP.md` to add the two extensions in Xcode (about 10 minutes), then run from Xcode.

Release: `flutter build appbundle` (Play Store), `flutter build ipa` (App Store) and `flutter build web` (laptop).
The GitHub workflow builds the APK and publishes the laptop version to GitHub Pages automatically.

## Tests

```bash
node tests/test_engine.js && node tests/test_sms.js && node tests/test_phone.js && node tests/test_new_checks.js && node tests/test_documents.js     # JS engine (web + iOS)
cd mobile/engine-java && node test/make_fixtures.js && javac -d build src/com/secondlook/engine/Engine.java src/com/secondlook/engine/Json.java test/EngineTest.java && java -cp build EngineTest
```

The Java test checks that the Android engine gives the same scores and reasons as the JS engine on 224 cases (including every UPI, payment and new-rule case from `tests/test_new_checks.js` and every document case from `tests/test_documents.js`, compared down to level labels, reason texts and advice, plus the document info fields). `make_fixtures.js` also writes `python/tests/new_checks_expected.json` and `python/tests/documents_expected.json` for the same checks in Python.

## Security

The app is hardened against hackers: encrypted storage with hardware-backed keys, messages and numbers never leave the phone, server-verified ads and purchases, no backups,
screen-sharing protection, app lock, tamper/root/hook detection, an obfuscated release build, and strict input limits.
See [SECURITY.md](SECURITY.md) for the full list and the steps left before a public launch.

## Store review notes

- Google Play restricts SMS permissions. See `docs/PLAY_STORE.md` for the exact declaration to submit.
- Apple: no special approval needed for Message Filter and Call Directory extensions. A future live caller lookup
  (iOS 18 Live Caller ID Lookup) needs Apple's approval and a privacy-preserving server.
