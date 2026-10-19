"""Writes build settings (from environment variables) as JSON for `flutter build --dart-define-from-file`.
Empty settings are left out, so the app falls back to its defaults (test ads, placeholders)."""
import json
import os

# Ad unit ids (see docs/ADS.md): banner, interstitial (after a manual check), native (sponsored cards), rewarded.
ADS = [f"ADMOB_{kind}_{os_}" for kind in ("BANNER", "INTERSTITIAL", "NATIVE", "REWARDED") for os_ in ("ANDROID", "IOS")]
KEYS = ["SL_API", *ADS, "SL_OPERATOR", "SL_ADDRESS", "SL_EMAIL", "SL_GRIEVANCE_NAME", "SL_GRIEVANCE_EMAIL", "SL_CITY"]
print(json.dumps({k: os.environ[k].strip() for k in KEYS if os.environ.get(k, "").strip()}))
