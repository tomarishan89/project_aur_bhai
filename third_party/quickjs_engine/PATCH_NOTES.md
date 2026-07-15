# Patched `quickjs_engine` (0.1.1)

Vendored from pub.dev to fix a Windows Flutter plugin registrar name mismatch:

- Upstream exports `QuickjsEnginePluginCApiRegisterWithRegistrar`
- Flutter codegen expects `QuickjsEnginePluginRegisterWithRegistrar`

Only `windows/include/.../quickjs_engine_plugin.h` and
`windows/quickjs_engine_plugin.cpp` differ from upstream for that fix.

## Android Gradle (local)

`android/build.gradle` was updated from AGP 7.4.2 / Kotlin 1.9.10 to AGP 9.0.1 /
Kotlin 2.3.20 so standalone IDE Gradle imports and the host Flutter app
(Gradle 9.x) can configure the plugin. Keep `android.builtInKotlin=false` in
`android/gradle.properties` until migrating off `kotlin-android`.

`android/settings.gradle` was removed so Cursor/VS Code Java+Gradle does not
treat this folder as a second Gradle root inside the Flutter workspace.
