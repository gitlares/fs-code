# Contributing

FS Code is an early native macOS editor. Keep changes focused, preserve unsaved documents, and use AppKit controls and English interface labels. Support light/dark appearances and accessibility. Internal panels use straight edges and native dividers.

Build with `bash scripts/build-app.sh`; run relevant tests with `swift test --build-system native`. Explain what changed, why, and how it was checked. UI changes need manual verification in the application; a successful build alone does not validate layout.

Do not commit `.fs/`, `.fscode/`, credentials, chat histories, build output, signing certificates, or personal project data. Add tests for behavior that could lose data or break authentication/session isolation.

Contributions are made under the repository's MIT license. Retain third-party licenses and document the provenance of borrowed code. Do not introduce telemetry.
