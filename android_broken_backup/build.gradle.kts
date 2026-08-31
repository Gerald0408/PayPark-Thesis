allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirect build outputs out of the sub-directories to a unified build folder
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// Global clean task
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Fix missing namespace in older third-party plugins (like `light`) for AGP 8+
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            if (namespace == null) {
                namespace = "com.example.${project.name.replace("-", "_")}"
            }
        }
    }
}