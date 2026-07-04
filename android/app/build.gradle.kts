plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.snippet"
    compileSdk = 36 // satisfy file_picker (34+) and other plugins (36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.snippet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: when the build provides a keystore via SNIPPET_KEYSTORE
    // (CI decodes it from a secret), sign with that so every build shares one
    // signature and installs as an update over the last. Explicit path — we do
    // NOT lean on AGP's implicit ~/.android/debug.keystore lookup, which resolves
    // to a different location on CI runners and silently signs with a freshly
    // generated key (the "package appears to be invalid" install failures).
    signingConfigs {
        create("release") {
            val ksPath = System.getenv("SNIPPET_KEYSTORE")
            if (ksPath != null && file(ksPath).exists()) {
                storeFile = file(ksPath)
                storePassword = System.getenv("SNIPPET_KEYSTORE_PASS") ?: "android"
                keyAlias = System.getenv("SNIPPET_KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("SNIPPET_KEY_PASS") ?: "android"
            }
        }
    }

    buildTypes {
        release {
            // Use the shared keystore when present; otherwise the local debug key
            // so `flutter run --release` still works on a dev machine.
            val ksPath = System.getenv("SNIPPET_KEYSTORE")
            signingConfig = if (ksPath != null && file(ksPath).exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
