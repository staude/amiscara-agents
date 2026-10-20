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
        versionCode = 1
        versionName = "0.1.0"
        // The ABIs build-android-ffi.sh builds; JNA would bring more, which
        // would then miss the core.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
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
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.zxing.core)
    implementation("${libs.jna.get()}@aar")

    debugImplementation(libs.androidx.ui.tooling)
}
