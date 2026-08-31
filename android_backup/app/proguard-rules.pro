# ---------- ML Kit ----------
# Optional script recognizers this app does not bundle (Latin only).
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }

# ---------- Firebase ----------
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keepclassmembers class * {
    @com.google.firebase.firestore.PropertyName <fields>;
}

# ---------- Flutter ----------
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ---------- Play Core (deferred components) ----------
-dontwarn com.google.android.play.core.**

# ---------- Reflection-sensitive metadata ----------
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
