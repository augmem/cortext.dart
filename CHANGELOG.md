# Changelog

All notable changes to the **cortext** Dart package (repository: **cortext.dart**)
are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## Unreleased

Requires the next cortext.cpp engine release (engine v5, per-blob content
timestamps and reference-time retrieval; cortext.cpp `main` at f0b681e9). No
released engine has these features yet, so the package version and the pinned
assets version stay at 1.2.4 until that release.

### Breaking

- `Config.proceduralEnabled` and the `procedural_enabled` field of the native
  `cortext_config` struct are removed (C struct layout change). The engine flag
  controlled nothing and was removed from the C ABI; this binding requires an
  engine built without it.
- The native `cortext_process_json_options` struct gains `has_reference_ms`,
  `as_of` and `reference_ms` after `evidence_budget_bytes`; options are now
  initialized through `cortext_process_json_options_init`.
- Recalled memories are no longer trimmed to 3 KiB of content by the engine:
  they come back whole unless `evidenceBudgetBytes` is set.
- Soft Anchors are gone from the engine (config, stats, memory fields and JSON
  keys); this binding never exposed them.
- Whenever an AIST model is in use, the engine requires its late-interaction
  reranker `AIST-87M-LI.gguf` (via `CORTEXT_LI_MODEL_PATH`, beside the AIST
  model, or linked into the native library) or engine creation fails.

### Added

- `ProcessOptions.referenceTime` and `ProcessOptions.asOf`: reference-time
  retrieval for query (`Retention.ephemeral`) calls. A reference time adds the
  long-term memories nearest it as candidates; `asOf` hides memories stored
  after it. Invalid combinations throw `ArgumentError` before the native call.
- Per-blob content timestamps: every `content[]` entry carries `timestamp`
  (ms since the Unix epoch, 0 when unknown).
- `ProcessOptions.evidenceBudgetBytes` and the `evidence_budget_bytes` field of
  the native options struct: a per-call evidence budget (null returns recalled
  memories whole), plus `mediaEvidenceBytes` (480), the charge of one non-text
  payload.
- `standing_memory` block: standing directives for a query, returned apart
  from `retrieved_memory` and not counted against a cut of it.
- Mixed-modality memories: `modality` can be `"mixed"`, each `content[]` entry
  carries its own `mimetype`, and a memory's `mimetype` is its first signal's.
- Text with caller media through `processTextWithMedia` and its JSON/options
  FFI entry points, preserving arbitrary binary bytes and MIME types; `text/*`
  media is used as text, empty media stores the canonical text, and the
  evidence budget applies.
- `findLiModelPath()` and `liModelFileName`: the binding resolves the
  late-interaction reranker (`CORTEXT_LI_MODEL_PATH`, beside AIST, or an assets
  tree) and pins it for engine creation alongside an AIST model it pins.
- Regenerated FFI bindings from cortext.cpp `main` (f0b681e9) `capi.h`,
  including the external store callback entry points.
- README: query contexts lead with `standing_memory`; reference time, text with
  media and LI model resolution are documented.

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
