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
subprojects {
    project.evaluationDependsOn(":app")
}

// Bump every module's Java compilation to 17 so it matches the Kotlin target.
// Plugins like receive_sharing_intent compile Kotlin at 17 but default Java to
// 11, failing with "Inconsistent JVM Target Compatibility". Registered via
// projectsEvaluated (after every module + AGP has configured) so this wins;
// touching only JavaCompile avoids needing Kotlin plugin types on the root
// classpath. (afterEvaluate can't be used here — the evaluationDependsOn block
// above already evaluates projects.)
gradle.projectsEvaluated {
    allprojects {
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
