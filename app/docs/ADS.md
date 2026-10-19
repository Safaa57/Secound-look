# Ads and Deep check

Second Look is **fully free**. There are no purchases or subscriptions: ads from Google AdMob pay for it.
Ads never see SMS, calls, documents or what the user checks, and they never get in the way of protection.

How it works for the user:

- The basic check of any link, SMS, number, UPI ID, payment screenshot or document is **free and unlimited**,
  on phone and laptop. SMS Shield and Call Shield are free.
- **Deep check** (optional, online) checks a link against Google Web Risk and the Phishing.Database blocklist.
  Everyone gets **3 free deep checks a day** (reset at midnight India time). After 3, the user can
  **watch a short ad for 1 more** (phone only).
- The **laptop (web) version has no ads at all**: the ads library isn't even in the web build.

## Where ads appear (phones only)

| Ad | Where | Rules |
|---|---|---|
| Banner (anchored adaptive) | Just above the bottom bar on **Home, Check and Alerts** only | Framed in the app's style with a "Sponsored" label. Takes no space if no ad loads. Never on a result, sender conversation, popup, "Being scammed?", onboarding or Me. |
| Native (Google template, dark) | One card on Home (under the tools and the help button), one after every 8 conversations in Alerts, 3 cards on **Offers** | "Sponsored" label. Only shown once loaded; never while choosing conversations to delete. |
| Interstitial (full screen) | After a **manual** check: Check anything, paste, share to Second Look, and the message, number, payment, UPI/QR and document tools | See the rules below. |
| Rewarded | "Watch a short ad for 1 more deep check", and the optional "Support Second Look — watch a short ad" on Offers | Always started by the user. Support ads unlock nothing. |

Full-screen ad rules (`lib/monetize/ad_rules.dart`):

- Never for SMS or Call Shield, the call/SMS popup, Alerts, "Being scammed?", Protection check or onboarding.
- The **first manual check ever** is ad-free. From the second on, the **result shows immediately** and the ad comes
  only when the user leaves the result (back or done).
- **No ad after a "Likely scam" result**: someone who just learned they're being scammed is never interrupted.
- No ad if the user tapped **Block, Report or Call 1930** on that result.
- **At most one full-screen ad every 2 minutes** (a rewarded ad also counts).
- Only if an ad is **already loaded** (the next one is loaded in the background): offline or no fill means no ad,
  and the user never waits.
- The counter and last-ad time are kept on the device (prefs `checks_done`, `last_ad_at`).
- In the battery saver look ads still show, but only one ad loads at a time.

## Consent (Google UMP)

Before any ad is requested the app runs Google's User Messaging Platform: it updates the consent status and shows
Google's consent form only where the law requires it (for example the EEA, UK and Switzerland). Ads load only if
`canRequestAds()` allows it. Users can change their choice in **Me → Your privacy → Ad choices** (Google's privacy
options form where required, otherwise a short explanation).

In AdMob: **Privacy & messaging → European regulations** → create and publish a GDPR message for the app (and a US
states message if you serve the US). Without a published message, users in those regions won't get ads.

Requests are non-personalised (`nonPersonalizedAds`), rated **G**, and not child-directed. They carry no keywords
or content from the app.

## 1. AdMob setup

1. [admob.google.com](https://admob.google.com) → Apps → Add app (Android, then again for iOS).
2. Ad units, for each platform:
   - **Banner** (it's shown as an anchored adaptive banner).
   - **Interstitial**.
   - **Native advanced** (the app uses Google's native templates; no custom layout needed).
   - **Rewarded** → reward amount `1`, item `deep_check`.
3. Rewarded ad unit → **Server-side verification** → callback URL:
   `https://<your-service>.onrender.com/v1/admob/ssv` → Verify URL. The server checks Google's signature on every
   reward and accepts each one only once, so nobody can fake credits. "Support" ads send no install id, so they never
   add credits.
4. **Blocking controls** → Sensitive categories, block: Gambling & betting, Dating, Get-rich-quick, Cryptocurrency,
   Personal loans, Debt services, Weight loss, Cosmetic procedures, Drugs & supplements, Astrology & esoteric,
   Politics, Religion. General categories, also block: Financial services → Credit & lending, Investing.
   (A scam-protection app must never show a loan or "investment" ad.)
5. **Blocking controls → Ad content rating**: max **G**. The app also enforces G in code.
6. **Privacy & messaging**: set up the consent messages (see above).

Put the ids into the build (GitHub repo → Settings → Secrets and variables → Actions → **Variables**):

| Variable | Example |
|---|---|
| `SL_API` | `https://secondlook-api.onrender.com` (no slash at the end) |
| `ADMOB_APP_ID_ANDROID` | `ca-app-pub-1234567890123456~1234567890` |
| `ADMOB_BANNER_ANDROID` | `ca-app-pub-1234567890123456/1111111111` |
| `ADMOB_INTERSTITIAL_ANDROID` | `ca-app-pub-1234567890123456/2222222222` |
| `ADMOB_NATIVE_ANDROID` | `ca-app-pub-1234567890123456/3333333333` |
| `ADMOB_REWARDED_ANDROID` | `ca-app-pub-1234567890123456/4444444444` |

For iPhone builds on a Mac (`tool/defines.py` also reads the `_IOS` variables):

```bash
ADMOB_APP_ID_IOS=ca-app-pub-...~... ./tool/setup.sh
flutter build ipa --obfuscate --split-debug-info=build/symbols \
  --dart-define=SL_API=https://secondlook-api.onrender.com \
  --dart-define=ADMOB_BANNER_IOS=ca-app-pub-.../... \
  --dart-define=ADMOB_INTERSTITIAL_IOS=ca-app-pub-.../... \
  --dart-define=ADMOB_NATIVE_IOS=ca-app-pub-.../... \
  --dart-define=ADMOB_REWARDED_IOS=ca-app-pub-.../...
```

Without these, Google's official **test** ids are used, so test builds show "Test Ad" and never earn or cost money.

## 2. Deploy the server (for Deep check; about 15 minutes)

Deep check needs the server; ads don't. Until you build with `SL_API`, the app simply hides the Deep check card,
and everything else (including ads) works.

The server is in `python/` (FastAPI). Easiest: **Render.com** (free tier is fine to start).

1. Put the `python/` folder in a GitHub repo.
2. Render → New → Web Service → pick the repo → it finds the `Dockerfile`.
3. Add a **disk** mounted at `/data` (keeps the daily counter and ad credits).
4. Environment variables:

| Variable | What to put |
|---|---|
| `WEB_RISK_API_KEY` | Google Cloud → enable **Web Risk API** → create an API key (restrict it to Web Risk). First 100,000 checks a month are free. Optional: without it, only Phishing.Database is used. |
| `SL_FREE_DEEP_PER_DAY` | Optional, default `3`. |

5. Deploy. Check `https://<your-service>.onrender.com/v1/status` shows `"ok": true`.

The server keeps only: random install id, today's count and ad credits. No names, numbers, emails, messages or links.

## 3. Laptop (web)

The GitHub workflow builds the laptop version and publishes it to GitHub Pages:
`https://<your-github-username>.github.io/<repo-name>/`

One-time: repo → Settings → **Pages** → Source: **GitHub Actions**.

On a laptop there are no ads and nothing to buy. It gets the 3 free deep checks a day.

## 4. Money, roughly

- Banners and native ads in India earn little per view; full-screen and rewarded ads earn more
  (roughly ₹0.3–₹1.5 per completed rewarded view; it varies a lot by month and audience).
- Web Risk costs nothing up to 100,000 lookups a month, then about $0.50 per 1,000.
- Keep the rules respectful: a safety app lives on trust and recommendations, not on ad pressure.
