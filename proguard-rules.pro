# ---- Flutter ----
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# ---- Firebase / Firestore / Auth ----
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Firestore serialises model classes via reflection
-keepclassmembers class * {
    @com.google.firebase.firestore.PropertyName <fields>;
}

# ---- ML Kit text recognition ----
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.odml.** { *; }
-dontwarn com.google.mlkit.**

# ---- CameraX ----
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# ---- Misc ----
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class javax.annotation.** { *; }
-dontwarn javax.annotation.**
