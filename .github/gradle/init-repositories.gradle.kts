// GitHub runners on the current image cannot fetch Kotlin plugin artifacts
// (2.3.20) through the Gradle Plugin Portal mirror. Prefer Maven Central for
// plugin/buildscript resolution in every build, including Flutter's included
// `flutter_tools/gradle` build.
beforeSettings {
    pluginManagement.repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}
