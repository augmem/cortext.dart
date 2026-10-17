# Changelog

All notable changes to the **cortext** Dart package (repository: **cortext.dart**)
are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## Unreleased

### Removed

- `Config.proceduralEnabled` and the `procedural_enabled` field of the native
  `cortext_config` struct. The engine flag controlled nothing and was removed
  from the C ABI; this binding requires an engine built without it.

### Added

- Text media payload support through `processTextWithMedia` and its JSON/options
  FFI entry points, preserving arbitrary binary bytes and MIME types.

## [1.2.4] - 2026-07-24

### Added

- Standalone **cortext.dart** repository for Dart FFI bindings.
- Publishable `pubspec.yaml` (package name `cortext`) with repository metadata.
- Release-asset resolution via `CortextAssets.ensure()` (GitHub
  `cortext-assets-<version>.tar.gz`), matching `cortext.go`.
- Library search paths for package-vendored `native/<platform-tag>/`, monorepo
  engine builds, and `CORTEXT_LIBRARY_PATH` / `CORTEXT_ASSETS_DIR`.
- `consolidation_state` normalization for older natives.
- Contract and API tests; CI workflow.
- `scripts/fetch_assets.sh` for offline / CI prep.

### Notes

- Binding version **1.2.4** tracks Cortext engine assets **v1.2.4**.
- Continuity: API mirrors the former monorepo `bindings/dart` package.
