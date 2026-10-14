# Deep check, rewarded ads and Second Look Plus

How it works for the user:

- The basic check of any link, SMS or number is **free, unlimited and has no ads**, on phone and laptop.
- **Deep check** (optional, online) checks a link against Google Web Risk and the Phishing.Database blocklist.
  Everyone gets **3 free deep checks a day** (reset at midnight India time).
- After 3, the user can **watch a short ad for 1 more** (phone only), or get **Plus**.
- **Plus** (monthly or yearly): unlimited deep checks, no ads, and link up to 3 more devices (for example a laptop)
  with a one-time code.

Nothing works until you deploy the server and build the app with its address. Until then the app simply hides the
Deep check card and the Plus tile, and everything else works.

---

## 1. Deploy the server (about 15 minutes)

The server is in `python/` (FastAPI). Easiest: **Render.com** (free tier is fine to start).

1. Put the `python/` folder in a GitHub repo.
2. Render → New → Web Service → pick the repo → it finds the `Dockerfile`.
3. Add a **disk** mounted at `/data` (keeps the counter and Plus database).
4. Environment variables:

| Variable | What to put |
|---|---|
| `WEB_RISK_API_KEY` | Google Cloud → enable **Web Risk API** → create an API key (restrict it to Web Risk). First 100,000 checks a month are free. Optional: without it, only Phishing.Database is used. |
| `PLAY_PACKAGE` | `com.secondlook.second_look` |
| `PLAY_SERVICE_ACCOUNT_JSON` | JSON of a Google Cloud service account that has access in Play Console (Users and permissions → invite the service account → "View financial data"). |
| `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_BUNDLE_ID` | App Store Connect → Users and Access → Integrations → **In-App Purchase** key. Bundle id e.g. `com.secondlook.secondLook`. |
| `APPLE_ENV` | `Sandbox` while testing, remove for production. |
| `SL_FREE_DEEP_PER_DAY` | Optional, default `3`. |

Never set `SL_DEV_PLUS` in production (it allows a fake "dev-plus" purchase for testing).

5. Deploy. Check `https://<your-service>.onrender.com/v1/status` shows `"ok": true`.

The server keeps only: random install id, today's count, ad credits, Plus expiry and link codes. No names, numbers,
emails, messages or links.

## 2. AdMob (rewarded ads)

1. [admob.google.com](https://admob.google.com) → Apps → Add app (Android, then again for iOS).
2. Ad units → **Rewarded** → reward amount `1`, item `deep_check`.
3. In the ad unit → **Server-side verification** → callback URL:
   `https://<your-service>.onrender.com/v1/admob/ssv` → Verify URL. The server checks Google's signature on every
   reward and accepts each one only once, so nobody can fake credits.
4. **Blocking controls** → Sensitive categories, block: Gambling & betting, Dating, Get-rich-quick, Cryptocurrency,
   Personal loans, Debt services, Weight loss, Cosmetic procedures, Drugs & supplements, Astrology & esoteric,
   Politics, Religion. General categories, also block: Financial services → Credit & lending, Investing.
   (A scam-protection app must never show a loan or "investment" ad.)
5. **Blocking controls → Ad content rating**: max **G**. The app also enforces G in code and asks for
   non-personalised ads only.
6. Privacy & messaging → set up the GDPR/consent message if you serve users in Europe.

Put the ids into the build (GitHub repo → Settings → Secrets and variables → Actions → **Variables**):

| Variable | Example |
|---|---|
| `SL_API` | `https://secondlook-api.onrender.com` (no slash at the end) |
| `ADMOB_APP_ID_ANDROID` | `ca-app-pub-1234567890123456~1234567890` |
| `ADMOB_REWARDED_ANDROID` | `ca-app-pub-1234567890123456/1234567890` |

For iPhone builds on a Mac:

```bash
ADMOB_APP_ID_IOS=ca-app-pub-...~... ./tool/setup.sh
flutter build ipa --obfuscate --split-debug-info=build/symbols \
  --dart-define=SL_API=https://secondlook-api.onrender.com \
  --dart-define=ADMOB_REWARDED_IOS=ca-app-pub-.../...
```

Without these, Google's **test** ids are used, so test builds show "Test Ad" and never earn or cost money.

## 3. Plus subscriptions

Create two subscriptions with **exactly** these product ids:

- `secondlook_plus_monthly`
- `secondlook_plus_yearly`

**Google Play Console** → Monetize → Subscriptions → Create (add a base plan with the price, e.g. ₹49/month, ₹399/year).
**App Store Connect** → your app → Subscriptions → one group "Second Look Plus" with both.

After a purchase the app sends the store receipt to your server, which checks it directly with Google or Apple before
turning on Plus. Restore purchases works on both stores.

Testing: Play Console → License testing (add your Gmail), or an Apple Sandbox tester.

## 4. Laptop (web)

The GitHub workflow builds the laptop version and publishes it to GitHub Pages:
`https://<your-github-username>.github.io/<repo-name>/`

One-time: repo → Settings → **Pages** → Source: **GitHub Actions**.

On a laptop there are no ads and no store. Users with Plus open Plus on their phone → **Get a link code** → type it on
the laptop. Without Plus, the laptop still gets the 3 free deep checks a day.

## 5. Money, roughly

- Rewarded ads in India pay roughly ₹0.3–₹1.5 per completed view (varies a lot by month and audience).
- Web Risk costs nothing up to 100,000 lookups a month, then about $0.50 per 1,000.
- A ₹49/month Plus at 1% of active users usually earns more than ads. Keep the free tier generous: it's what makes
  people trust and recommend a safety app.
