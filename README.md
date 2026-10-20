# cortext.dart

Dart FFI bindings for [Cortext](https://github.com/augmem/cortext).

This repository is the language-binding home for Dart — the sibling of
[`cortext.py`](https://github.com/augmem/cortext.py),
[`cortext.go`](https://github.com/augmem/cortext.go), and
[`cortext.ts`](https://github.com/augmem/cortext.ts). It publishes the
[pub.dev](https://pub.dev) package **`cortext`**.

Binding **2.0.0** tracks engine assets **v2.0.0**.

## Install

```bash
dart pub add cortext
# or in pubspec.yaml:
# dependencies:
#   cortext: ^2.0.0
```

Dart SDK **3.5+**. Desktop/server targets:

| Platform tag   | Library            |
| -------------- | ------------------ |
| `linux-x86_64` | `libcortext.so`    |
| `linux-aarch64`| `libcortext.so`    |
| `macos-x86_64` | `libcortext.dylib` |
| `macos-aarch64`| `libcortext.dylib` |
| `windows-x86_64` | `cortext.dll`    |
| `windows-aarch64`| `cortext.dll`    |

Natives are **not** committed to git. On first use the package resolves them
from (in order):

1. `CORTEXT_LIBRARY_PATH`
2. `CORTEXT_ASSETS_DIR` / package-vendored `native/<tag>/`
3. Sibling monorepo engine build outputs (dev)
4. GitHub Release `cortext-assets-<version>.tar.gz` (download once into cache)
5. Bare system library name

Offline prep:

```bash
./scripts/fetch_assets.sh /path/to/assets
export CORTEXT_ASSETS_DIR=/path/to/assets
```

## Quickstart

```dart
import 'package:cortext/cortext.dart';

void main() {
  final memory = Cortext(
    dbPath: 'memory.sqlite',
    config: const Config(
      focus: 0.55,
      sensitivity: 0.5,
      stability: 0.65,
    ),
  );

  try {
    memory.processText(
      'The garage door code is 8841.',
      'user/profile',
      const ProcessOptions(
        includeEmbedding: false,
        retention: Retention.durable,
      ),
    );

    final ctx = memory.processText(
      'What should I remember about the garage?',
      'chat/assistant',
      const ProcessOptions(
        includeEmbedding: false,
        retention: Retention.ephemeral,
      ),
    );

    for (final item in (ctx['retrieved_memory'] as List?) ?? const []) {
      print(item);
    }

    if (ctx['consolidation_state'] != 'none') {
      memory.consolidate();
    }
  } finally {
    memory.flush();
    memory.close();
  }
}
```

Use `dbPath: ':memory:'` for a temporary engine.

A query context leads with `standing_memory` (standing directives such as
"Always ...", outside the retrieved ranking; show it ahead of
`retrieved_memory` and do not count it against a cut of the retrieved list),
then `retrieved_memory`. `ProcessOptions(evidenceBudgetBytes: ...)` (null =
whole memories) fits both within a byte budget: text counts its UTF-8 bytes,
other payloads 480 bytes each, grouped memories keep their members most
similar to the query, and more distinct memories are kept trimmed before
lower-ranked ones are left out (8,000 tokens at 4.35 chars/token is 34,800
bytes).

Each memory in `standing_memory` / `retrieved_memory` / `working_memory`
carries `content`: every signal payload of the memory as
`{size_bytes, mimetype, timestamp, base64}`, in signal order, whole unless an
evidence budget trims it. `timestamp` is that payload's stored signal time in
milliseconds since the Unix epoch (`0` when unknown). `modality` is the
modality its signals share, or `"mixed"` when they differ (for example a turn's
text and the photo sent with it under one source), and the memory's `mimetype`
is the MIME type of its first signal.

### Reference time

A query (`Retention.ephemeral`) can be asked as of another time:

```dart
final ctx = memory.processText(
  'Where did we park?',
  'query/public',
  ProcessOptions(
    retention: Retention.ephemeral,
    referenceTime: DateTime.utc(2026, 3, 14, 18),
    asOf: true,
  ),
);
```

`referenceTime` (past or future, millisecond precision) adds the long-term
memories nearest that time as retrieval candidates; with `asOf: true`, memories
stored after it are hidden. Without `referenceTime` retrieval is unchanged.
`asOf` without `referenceTime`, a `referenceTime` at or before the Unix epoch, or a
`referenceTime` on a non-ephemeral call throws `ArgumentError`.

### Text with caller media

`processTextWithMedia(text, sourceId, media, [options])` encodes `text` but
stores `media` (bytes plus MIME type) as the memory payload, for example the
original image or document a caption describes. A `text/*` MIME type is used
as text (keyword index, standing memories, packet text); any other type is an
opaque payload charged `mediaEvidenceBytes` (480) under an evidence budget.
Null or empty media stores the text itself.

## API

| Symbol | Notes |
| --- | --- |
| `Cortext` | Engine handle (`processText`, `processTextWithMedia`, `embedText`, audio/image, `consolidate`, `flush`, `reset`, `close`) |
| `Config`, `Media`, `ProcessOptions`, `Retention` | Configuration types (`ProcessOptions`: `includeEmbedding`, `retention`, `evidenceBudgetBytes`, `referenceTime`, `asOf`) |
| `mediaEvidenceBytes` | Evidence charge of one non-text payload (480) |
| `findAistModelPath()`, `findLiModelPath()` | On-disk AIST model and reranker resolution |
| `CortextLibrary` | Low-level dynamic library open + `version` / `lastError` |
| `CortextAssets.ensure()` | Download/unpack release assets (sync) |
| `platformTag()`, `packageVersion`, `defaultAssetsVersion` | Platform / version helpers |

Audio input is **16 kHz mono float32 PCM**. Image input is row-major RGB/RGBA
with explicit dimensions. `Media` payloads accept arbitrary binary bytes plus a
MIME type; use `processTextWithMedia`, `processAudioWithMedia`, or
`processImageWithMedia` to persist a source payload alongside the signal.
Undersized image buffers are rejected before native calls.

Decoded process maps always include `consolidation_state`
(`none` \| `recommended` \| `required`), including when older natives only
return boolean flags.

## Environment

| Variable | Role |
| --- | --- |
| `CORTEXT_LIBRARY_PATH` | Explicit shared library path |
| `CORTEXT_ASSETS_DIR` | Pre-unpacked release tree (`native/` + `models/`) |
| `CORTEXT_ASSETS_VERSION` | Release version to fetch (default `2.0.0`) |
| `CORTEXT_ASSETS_URL` | Override archive URL |
| `CORTEXT_ASSETS_SHA256` | Override expected archive checksum |
| `CORTEXT_ASSET_CACHE_DIR` | Parent cache dir for downloaded versions |
| `CORTEXT_AIST_MODEL_PATH` | Optional explicit full AIST `.gguf` (engine-side) |
| `CORTEXT_LI_MODEL_PATH` | Optional explicit late-interaction reranker `AIST-87M-LI.gguf` (engine-side) |

Whenever an AIST model is in use the engine also needs its late-interaction
reranker, `AIST-87M-LI.gguf`: from `CORTEXT_LI_MODEL_PATH`, else beside the
AIST model, else the copy linked into the native library; otherwise creating
an engine fails. When the binding finds a full AIST GGUF on disk
(`CORTEXT_ASSETS_DIR`, the release assets cache, or a sibling engine checkout)
it pins `CORTEXT_AIST_MODEL_PATH` for `cortext_create`, and pins
`CORTEXT_LI_MODEL_PATH` to the reranker found the same way
(`findLiModelPath()`), unless you set either yourself.

## Develop

```bash
git clone https://github.com/augmem/cortext.dart.git
cd cortext.dart
dart pub get

# Option A: fetch release natives
./scripts/fetch_assets.sh
export CORTEXT_ASSETS_DIR="$HOME/Library/Caches/augmem/cortext/assets/2.0.0"  # macOS default

# Option B: monorepo engine checkout at ../cortext with ffi-release build

dart test
dart analyze
```

### Regenerate FFI bindings

Requires a local [augmem/cortext.cpp](https://github.com/augmem/cortext.cpp) checkout:

```bash
# from cortext.dart with ../cortext present
dart run ffigen --config ffigen.yaml
dart format --language-version=latest lib/src/cortext_bindings.dart
```

To test against a local engine build, point the overrides at it:

```bash
CORTEXT_LIBRARY_PATH=/path/to/libcortext.dylib \
CORTEXT_ASSETS_DIR=/path/to/models \
CORTEXT_LI_MODEL_PATH=/path/to/models/AIST-87M-GGUF/AIST-87M-LI.gguf \
dart test
```

`lib/src/cortext_bindings.dart` is generated; do not hand-edit.

## Repository layout

```text
cortext.dart/
  lib/                 package sources
  test/                unit + native integration tests
  scripts/             fetch_assets.sh
  native/              optional vendored natives (gitignored binaries)
  ffigen.yaml          regenerate C ABI bindings
  .github/workflows/   CI
```

## Maintainer release flow

```bash
# 1) Bump version in pubspec.yaml + CHANGELOG.md + lib/src/version.dart
# 2) dart pub get && dart analyze && dart test
# 3) git tag v2.0.0 && git push origin v2.0.0
# 4) dart pub publish
```

## Why a separate repo?

| Repo | Role |
| --- | --- |
| [`augmem/cortext`](https://github.com/augmem/cortext) | Super-repo (all language variants) |
| [`augmem/cortext.cpp`](https://github.com/augmem/cortext.cpp) | Engine (C++/Zig) |
| [`augmem/cortext.py`](https://github.com/augmem/cortext.py) | Python |
| [`augmem/cortext.go`](https://github.com/augmem/cortext.go) | Go |
| [`augmem/cortext.ts`](https://github.com/augmem/cortext.ts) | TypeScript / Node |
| **`augmem/cortext.dart`** | Dart / Flutter-friendly FFI package |

Language bindings follow their ecosystem’s packaging norms. Dart belongs on
pub.dev with `dart:ffi`, not only under the engine monorepo’s `bindings/dart`.

## License

Apache-2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
