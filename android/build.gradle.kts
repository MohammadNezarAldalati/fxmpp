group = "dev.hainguyen.fxmpp"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

plugins {
    id("com.android.library")
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

android {
    namespace = "dev.hainguyen.fxmpp"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 30
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Exclude duplicate XPP3 dependencies
configurations.all {
    exclude(group = "xpp3", module = "xpp3")
    exclude(group = "xpp3", module = "xpp3_min")
}

dependencies {
    implementation("org.igniterealtime.smack:smack-android-extensions:4.4.6")
    implementation("org.igniterealtime.smack:smack-tcp:4.4.6")
    implementation("org.igniterealtime.smack:smack-im:4.4.6")
    implementation("org.igniterealtime.smack:smack-extensions:4.4.6")
}
