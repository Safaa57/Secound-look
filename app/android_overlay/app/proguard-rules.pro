# Second Look release build (R8): shrink and obfuscate with the standard, safe settings.
# (Aggressive options like -repackageclasses / -overloadaggressively were removed: they can break
#  libraries that look up classes by name at runtime and crash the app at start.)

# Strip verbose logging from release builds.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}

# libphonenumber loads its metadata by resource path; keep it intact.
-keep class com.google.i18n.phonenumbers.** { *; }
-dontwarn com.google.i18n.phonenumbers.**

# Our own code is small; keep it readable by the system (activities, services, receivers, method channel).
-keep class com.secondlook.** { *; }

# Flutter and plugins ship their own rules; silence warnings for optional Play Core classes.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.**
