allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Normalize every module (app + plugins). Registered BEFORE the
// evaluationDependsOn block below so afterEvaluate isn't called on
// already-evaluated projects.
//  - compileSdk 36: flutter_plugin_android_lifecycle (via file_picker) requires
//    consumers to compile against API 36; older plugins default to 34/35.
//  - Java 17: receive_sharing_intent compiles Kotlin at 17 but Java at 11,
//    failing with "Inconsistent JVM Target Compatibility".
// The android extension is configured via reflection so the root build script
// doesn't need AGP/Kotlin plugin types on its classpath.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { android ->
            try {
                android.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(android, 36)
            } catch (e: Exception) {
                logger.warn("compileSdk 36 not set for ${project.name}: ${e.message}")
            }
        }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
