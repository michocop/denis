import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// One configuration for both apps: the Supabase URL and anon key are read from
// ios/Config.xcconfig (git-ignored). Missing, the app starts in demo mode, as
// the iPhone app does. The anon key ships in the app by design: every table is
// behind Row Level Security.
fun xcconfig(): Map<String, String> {
    val file = File(rootDir, "../ios/Config.xcconfig")
    if (!file.exists()) return emptyMap()
    val raw = file.readLines()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("//") && it.contains("=") }
        .associate { it.substringBefore("=").trim() to it.substringAfter("=").trim() }
    val slashes = "//"
    return raw.mapValues { (_, v) -> v.replace("\$(SUPABASE_SLASHES)", slashes).replace("\$()", "") }
}
val config = xcconfig()

// Release signing: the upload key in android/signing/ (git-ignored), its
// password in the macOS Keychain, or in ANDROID_UPLOAD_KEY_PASSWORD on a CI.
// Asked for only when a release is being built, never for a debug build.
val signing = Properties().apply {
    File(rootDir, "keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
val buildingRelease = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
fun uploadKeyPassword(): String? = System.getenv("ANDROID_UPLOAD_KEY_PASSWORD")
    ?: runCatching {
        ProcessBuilder("security", "find-generic-password", "-s", "trinity-android-upload-key", "-w")
            .start().inputStream.bufferedReader().readText().trim()
    }.getOrNull()?.takeIf { it.isNotEmpty() }

// Push (FCM) without the google-services plugin: the four values Firebase
// gives for the Android app, from android/firebase.properties (git-ignored;
// firebase.properties.example says where each one is). Missing, they are
// empty, and the app never initialises Firebase nor contacts Google.
fun firebaseProperties(): Properties {
    val props = Properties()
    val file = File(rootDir, "firebase.properties")
    if (file.exists()) file.inputStream().use { props.load(it) }
    return props
}
val firebase = firebaseProperties()
fun firebaseField(name: String) = "\"${(firebase.getProperty(name) ?: "").trim().replace("\"", "")}\""

android {
    namespace = "com.trinityenergie.energycourtage"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.trinityenergie.energycourtage"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "SUPABASE_URL", "\"${config["SUPABASE_URL"] ?: ""}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${config["SUPABASE_ANON_KEY"] ?: ""}\"")
        buildConfigField("String", "FIREBASE_PROJECT_ID", firebaseField("FIREBASE_PROJECT_ID"))
        buildConfigField("String", "FIREBASE_APP_ID", firebaseField("FIREBASE_APP_ID"))
        buildConfigField("String", "FIREBASE_API_KEY", firebaseField("FIREBASE_API_KEY"))
        buildConfigField("String", "FIREBASE_SENDER_ID", firebaseField("FIREBASE_SENDER_ID"))
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("upload") {
            val store = signing.getProperty("storeFile")?.let { File(rootDir, it) }
            if (buildingRelease && store != null && store.exists()) {
                val password = uploadKeyPassword() ?: error("Upload key password not found (Keychain item trinity-android-upload-key)")
                storeFile = store
                storePassword = password
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = password
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("upload").takeIf { it.storeFile != null }
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.biometric:biometric:1.1.0")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")
    // push; initialised by hand from BuildConfig (push/Push.kt), no google-services plugin
    implementation("com.google.firebase:firebase-messaging:24.1.2")
    // lead documents: the system document scanner (edge detection, perspective, PDF out)
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0-beta1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
