import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

if (project.layout.projectDirectory.file("google-services.json").asFile.exists()) {
    pluginManager.apply("com.google.gms.google-services")
}

// Release signing comes from the gitignored android/key.properties (see docs/handbook.md).
val keyProperties = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    namespace = "dev.relay.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (uses java.time APIs on older SDKs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.relay.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keyProperties.isEmpty) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Debug builds need no key; a release build without one fails instead of
// silently shipping a debug-signed or unsigned APK.
gradle.taskGraph.whenReady {
    if (keyProperties.isEmpty && allTasks.any { it.project == project && it.name.contains("Release") }) {
        throw GradleException("Release signing needs android/key.properties; see docs/handbook.md (Android release signing).")
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backports java.time used by flutter_local_notifications to minSdk levels.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
