# Second Look release hardening (R8): shrink, optimise and obfuscate our code.
-repackageclasses 'sl'
-allowaccessmodification
-overloadaggressively
# Strip all logging from release builds.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}
# libphonenumber loads its metadata by resource path; keep it intact.
-keep class com.google.i18n.phonenumbers.** { *; }
-dontwarn com.google.i18n.phonenumbers.**
# Components the system starts by name are kept automatically from the manifest.
