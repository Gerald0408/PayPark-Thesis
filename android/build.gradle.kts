buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.2.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 1. Auto Namespace Fix
subprojects {
    plugins.withId("com.android.library") {
        val androidExtension = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExtension != null && androidExtension.namespace == null) {
            androidExtension.namespace = group.toString()
        }
    }
    plugins.withId("com.android.application") {
        val androidExtension = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExtension != null && androidExtension.namespace == null) {
            androidExtension.namespace = group.toString()
        }
    }
}

// 2. FORCE Kotlin Plugin Strategy para sa LAHAT ng submodules
subprojects {
    buildscript {
        configurations.all {
            resolutionStrategy {
                force("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22")
            }
        }
    }
    configurations.all {
        resolutionStrategy {
            force("org.jetbrains.kotlin:kotlin-stdlib:1.9.22")
            force("org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.9.22")
            force("org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.9.22")
            force("org.jetbrains.kotlin:kotlin-reflect:1.9.22")
        }
    }
}