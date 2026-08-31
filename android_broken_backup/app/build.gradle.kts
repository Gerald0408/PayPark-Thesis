android {
    compileSdk 35
    ndkVersion flutter.ndkVersion

    compileOptions {
        coreLibraryDesugaringEnabled true
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId "com.concepcion.payparking"   // must match google-services.json
        minSdk = 23
        targetSdk 35
        multiDexEnabled true
        versionCode flutter.versionCode
        versionName flutter.versionName
    }

    buildTypes {
        release {
            signingConfig signingConfigs.debug   // swap for a real keystore before publishing
            minifyEnabled false
            shrinkResources false
        }
    }
}

dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'
    implementation 'androidx.multidex:multidex:2.0.1'
}
