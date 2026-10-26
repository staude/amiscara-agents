import java.util.Properties
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/**
 * Builds the Rust core (`herdr-ffi`) for every ABI and its Kotlin bindings
 * with `scripts/build-android-ffi.sh`. AGP takes both outputs as generated
 * sources, so every build runs this first.
 */
abstract class BuildRustCore @Inject constructor(private val exec: ExecOperations) : DefaultTask() {
    @get:Internal
    abstract val repoRoot: DirectoryProperty

    @get:Internal
    abstract val ndkDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val jniLibs: DirectoryProperty

    @get:OutputDirectory
    abstract val kotlin: DirectoryProperty

    init {
        // Cargo decides what to rebuild; a run without changes takes about
        // a second.
        outputs.upToDateWhen { false }
    }

    @TaskAction
    fun build() {
        exec.exec {
            workingDir = repoRoot.get().asFile
            environment("ANDROID_NDK_HOME", ndkDirectory.get().asFile.absolutePath)
            commandLine(
                repoRoot.file("scripts/build-android-ffi.sh").get().asFile.absolutePath,
                jniLibs.get().asFile.absolutePath,
                kotlin.get().asFile.absolutePath,
                "release",
            )
        }
    }
}

/** `version.properties`, kept by `scripts/android-release.sh`. */
val versions = Properties().apply { rootProject.file("version.properties").inputStream().use(::load) }

/**
 * The Play upload key, outside the repository: `keystore.properties` (not
 * checked in) names the file and alias, the password comes from the
 * environment (`scripts/android-release.sh` takes it from the Keychain).
 * Without them the release build stays unsigned.
 */
val upload = rootProject.file("keystore.properties").takeIf { it.exists() }
    ?.let { file -> Properties().apply { file.inputStream().use(::load) } }
val uploadPassword: String? = System.getenv("AMISCARA_UPLOAD_KEY_PASSWORD")

android {
    namespace = "net.staude.amiscara.agents"
    compileSdk = 37
    // Also strips the Rust library when packaging; BuildRustCore hands the
    // same NDK to build-android-ffi.sh.
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "net.staude.amiscara.agents"
        minSdk = 29
        targetSdk = 37
        versionCode = versions.getProperty("versionCode").toInt()
        versionName = versions.getProperty("versionName")
        // The ABIs build-android-ffi.sh builds; JNA would bring more, which
        // would then miss the core.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        if (upload != null && uploadPassword != null) {
            create("upload") {
                storeFile = file(upload.getProperty("storeFile"))
                keyAlias = upload.getProperty("keyAlias")
                storePassword = uploadPassword
                keyPassword = uploadPassword
            }
        }
    }

    buildTypes {
        release {
            // R8 would need keep rules for JNA and the UniFFI bindings.
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("upload")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // Version for the settings screen.
        buildConfig = true
    }
}

val buildRustCore = tasks.register<BuildRustCore>("buildRustCore") {
    repoRoot.set(rootProject.layout.projectDirectory.dir("../.."))
    ndkDirectory.set(androidComponents.sdkComponents.ndkDirectory)
}

androidComponents {
    onVariants { variant ->
        variant.sources.java?.addGeneratedSourceDirectory(buildRustCore, BuildRustCore::kotlin)
        variant.sources.jniLibs?.addGeneratedSourceDirectory(buildRustCore, BuildRustCore::jniLibs)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.androidx.glance.appwidget)
    implementation(libs.androidx.glance.material3)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.zxing.core)
    implementation("${libs.jna.get()}@aar")

    debugImplementation(libs.androidx.ui.tooling)

    testImplementation(libs.junit)
}
