package com.secondlook.second_look;

/**
 * Expected fingerprints, written by tool/setup.sh at build time.
 * Empty values switch a check off (development builds).
 */
final class Integrity {
    private Integrity() { }

    /** SHA-256 of assets/secondlook/rules.json */
    static final String RULES_SHA256 = "";
    /** SHA-256 of assets/secondlook/phone_data.json */
    static final String PHONE_DATA_SHA256 = "";
    /** SHA-256 of the release signing certificate (set SECONDLOOK_CERT_SHA256 when running setup.sh). */
    static final String SIGNING_CERT_SHA256 = "";
}
