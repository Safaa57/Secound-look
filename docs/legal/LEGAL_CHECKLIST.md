# Legal checklist before you publish Second Look

The app is built to avoid the usual legal problems: it collects almost no personal data, asks for consent before every
sensitive feature, explains that results are opinions, and gives users their data rights. The items below are things
**only you** can do. This is a practical checklist, not legal advice. Have an Indian technology lawyer review the
Terms, Privacy Policy and this list before launch (a one-time review is usually affordable and worth it).

## 1. Who publishes the app

- [ ] Decide the publisher: yourself (sole proprietor), an LLP or a private limited company. A company limits your
      personal liability if someone sues.
- [ ] Use the same name in Google Play Console, App Store Connect, AdMob, the Terms and the Privacy Policy.
- [ ] Set the operator details at build time (GitHub → Settings → Secrets and variables → Actions → Variables):

| Variable | Example |
|---|---|
| `SL_OPERATOR` | Second Look Technologies LLP |
| `SL_ADDRESS` | 12 MG Road, Bengaluru 560001 |
| `SL_EMAIL` | support@yourdomain.in |
| `SL_GRIEVANCE_NAME` | A. Sharma |
| `SL_GRIEVANCE_EMAIL` | grievance@yourdomain.in |
| `SL_CITY` | Bengaluru |

Until these are set, the in-app documents show placeholders like "[Operator name]". **Don't publish with placeholders.**

## 2. Name and brand

- [ ] Search the trademark register (ipindia.gov.in, classes 9 and 42) and the Play Store for "Second Look". The name
      is common; if someone already uses it for a similar app, rename now rather than after a legal notice.
- [ ] Don't use bank, app or government logos anywhere (the app uses names only, which is allowed to describe what a
      scam pretends to be). Keep the "not affiliated" line in the app and store listing.
- [ ] Never call the app "government approved", "RBI approved", "100% safe" or "guaranteed". Store text should say it
      "helps spot" scams.

## 3. Data protection (DPDP Act, 2023 and DPDP Rules, 2025)

The Rules were notified in November 2025; most duties (notice, consent, security, breach reporting, rights) apply
18 months later. Second Look is already designed to meet them:

- [x] Itemised notice in plain language (Privacy Policy) shown before consent.
- [x] Consent checkbox at first launch, recorded with the document version; re-asked when documents change.
- [x] Separate in-app disclosure before SMS Shield and Call Shield.
- [x] Right to access ("Your data on our server") and erasure ("Delete all my data", device and server).
- [x] Data minimisation: random install ID only; no names, numbers, contacts, messages or links stored on the server.
- [x] Automatic deletion: usage after 35 days, inactive installs after 12 months.
- [x] No tracking or targeted ads (important for children's data).
- [ ] Appoint and publish a Grievance Officer (name + email in the app and on your website). Reply within 24 hours,
      resolve within 15 days.
- [ ] Keep a simple breach plan: who decides, how users are told, and reporting to the Data Protection Board (a
      detailed report within 72 hours). Also report cyber incidents to CERT-In within 6 hours of noticing them.
- [ ] Choose a server host and region. If it's outside India, the Privacy Policy already says so.

## 4. Community reports (web app)

Shared "reported as scam" labels on phone numbers could be called defamatory by the number's owner.

- [x] Reports are shown as "reported by N users, not verified", never as fact.
- [x] Report reasons come from a fixed list (no free-text accusations published).
- [x] The web page has a "Is this your number? Request a review" link to the Grievance Officer.
- [ ] Remove or hide a disputed report within 36 hours of a valid complaint, and keep a short record of what you did.
- [ ] Never sell or publish the report list in bulk.

## 5. Store policies

- [ ] **Google Play SMS permission:** submit the Permissions Declaration (see `docs/PLAY_STORE.md`) with the demo video
      showing the in-app disclosure, agreeing, declining and the shield working.
- [ ] **Data safety form:** fill it exactly as in `docs/PLAY_STORE.md` (install ID, links for Deep check, purchases,
      AdMob and ML Kit diagnostics). It must match the Privacy Policy.
- [ ] **Ads:** declare "Contains ads". Target audience 18+ unless you join Google's Families programme.
- [ ] **Subscriptions:** the Plus screen shows the price and "Cancel any time in Google Play / App Store". Don't use
      fake timers or pre-ticked boxes (India's Dark Patterns Guidelines, 2023, ban these).
- [ ] **Apple:** App Privacy "nutrition label" to match the Privacy Policy; link the Terms (Apple's standard EULA
      also applies).
- [ ] **Google Web Risk:** keep "Advisory provided by Google" and the "may not be complete" wording (Google's terms
      require it). Don't show a Google-based warning in any other situation.

## 6. Money and tax

- [ ] Fill in tax details (PAN, and GST if registered) in AdMob, Play Console and App Store Connect.
- [ ] Ask a CA how to treat ad and subscription income and whether you need GST registration.

## 7. Licences

- [x] Open-source and data licences are listed in Settings › Open-source licences (libphonenumber Apache-2.0,
      libphonenumber-js MIT, Wikipedia-derived number data CC BY-SA 4.0, Phishing.Database MIT).
- [ ] If you publish the number-data file anywhere, keep the CC BY-SA 4.0 notice with it.

## 8. Keep records

- [ ] Save each published version of the Terms and Privacy Policy with its date (they're in git; tag releases).
- [ ] Keep grievance emails and replies for at least 1 year.
