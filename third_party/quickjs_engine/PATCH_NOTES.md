# Patched `quickjs_engine` (0.1.1)

Vendored from pub.dev to fix a Windows Flutter plugin registrar name mismatch:

- Upstream exports `QuickjsEnginePluginCApiRegisterWithRegistrar`
- Flutter codegen expects `QuickjsEnginePluginRegisterWithRegistrar`

Only `windows/include/.../quickjs_engine_plugin.h` and
`windows/quickjs_engine_plugin.cpp` differ from upstream.
