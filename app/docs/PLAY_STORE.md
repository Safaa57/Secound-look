# Google Play: permissions declaration

Second Look asks for only two sensitive permissions, and only when the user switches a shield ON.

| Permission | Why | When it's requested |
|---|---|---|
| `RECEIVE_SMS` | SMS Shield checks each new SMS on the device for scam links and tricks. | When the user turns SMS Shield ON. If they refuse, the shield stays OFF. |
| `POST_NOTIFICATIONS` | To warn the user about a scam SMS or call. | When a shield is turned ON. |

Not used: `READ_SMS` (we never read the inbox), `READ_CALL_LOG`, `READ_CONTACTS`, `RECORD_AUDIO`, location. Internet is used only for the optional Deep check (the link only), optional rewarded ads and Plus.

Call Shield uses Android's **Call screening role** (`RoleManager.ROLE_CALL_SCREENING`, Android 10+). That role
doesn't need call-log permissions. Android only passes calls from numbers that aren't in the user's contacts.

## SMS permission declaration form

`RECEIVE_SMS` is a restricted permission. In Play Console → App content → Sensitive permissions, declare the
core-functionality exception **"Caller ID, spam detection, and/or spam blocking"** (or **"Anti-SMS phishing (smishing)"**
once the app has a track record). Suggested description:

> Second Look is an anti-scam app. When the user turns on SMS Shield, the app checks each incoming SMS on the device for
> phishing links, fake bank/KYC alerts, UPI and other fraud patterns, and warns the user with a notification. Message
> content is analysed only on the device and is never uploaded or shared. The feature is off by default, can be switched
> off at any time, and the SMS receiver is disabled while it is off.

Also needed: a short video showing the user switching SMS Shield on and receiving a warning, and a privacy policy (see `PRIVACY.md`).
Google reviews these declarations, so approval isn't guaranteed. Until it's approved, ship with SMS Shield
hidden on Play builds; the Check tab, Share-to-check and Call Shield work without the SMS permission.


## Data safety form (Play Console)

- **Data shared:** none of the user's messages, call details or contacts.
- **Data collected:** Device or other IDs: a random install id (for the free deep-check counter and Plus; not linked to identity). Web browsing: URLs the user chooses to deep check (processed, not stored). App activity: purchase history (Plus status).
- **Payment screenshots / QR codes:** the words and QR codes in an image the user picks or shares are read **on the device only** (Google ML Kit text recognition + barcode scanning, models bundled in the app). The image and its contents are never uploaded, so they are not "collected". No photo/media permission is used (Android Photo Picker, or the single image another app shares).
- **Check a document (IDs, passports, bank statements, letters):** no new data is collected or shared. The PDF or photo the user picks is read **on the device only** (Android PdfRenderer + the same bundled ML Kit text recognition as above) and checked by the on-device engine. The document, its text and the result are never uploaded, never stored (not in history or alerts) and the temporary copy is deleted when the user leaves the screen. Aadhaar numbers are shown masked. No storage permission is used: the system file picker (`ACTION_OPEN_DOCUMENT`) grants access to just the one file the user picks. Nothing to add to the Data safety form beyond the ML Kit diagnostics below.
- **ML Kit SDK diagnostics:** per Google's [ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure), the ML Kit SDK itself sends Google device information (model, OS version), app information (package name, app version), performance metrics and error codes/diagnostics, to keep the SDK working and improve it. Declare these under **App info and performance › Diagnostics / Crash logs** and **Device or other IDs** as Google's guide describes: collected, not shared, encrypted in transit, not used for ads. No image content is part of it.
- **Ads:** declare "Contains ads" (AdMob rewarded, optional). AdMob collects Advertising ID; ads are non-personalised. Declare the SDK's data per Google's AdMob data-disclosure guide.
- **Encryption in transit:** yes (HTTPS only). **Deletion:** "Delete all my data" in Settings.
- **Target audience:** if you include children under 13, you must join Google's Families program and use only certified ad SDKs; simplest is to target 18+.
