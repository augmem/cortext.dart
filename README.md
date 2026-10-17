# cortext.dart

Dart FFI bindings for [Cortext](https://github.com/augmem/cortext).

This repository is the language-binding home for Dart — the sibling of
[`cortext.py`](https://github.com/augmem/cortext.py),
[`cortext.go`](https://github.com/augmem/cortext.go), and
[`cortext.ts`](https://github.com/augmem/cortext.ts). It publishes the
[pub.dev](https://pub.dev) package **`cortext`**.

Binding **1.2.4** tracks engine assets **v1.2.4**.

## Install

```bash
dart pub add cortext
# or in pubspec.yaml:
# dependencies:
#   cortext: ^1.2.4
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

Each memory in `retrieved_memory` / `working_memory` carries `content`: every
signal payload of the memory as `{size_bytes, mimetype, base64}`, in signal
order. `modality` is the modality its signals share, or `"mixed"` when they
differ (for example a turn's text and the photo sent with it under one source).

## API

| Symbol | Notes |
| --- | --- |
| `Cortext` | Engine handle (`processText`, `processTextWithMedia`, `embedText`, audio/image, `consolidate`, `flush`, `reset`, `close`) |
| `Config`, `Media`, `ProcessOptions`, `Retention` | Configuration types |
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
| `CORTEXT_ASSETS_VERSION` | Release version to fetch (default `1.2.4`) |
| `CORTEXT_ASSETS_URL` | Override archive URL |
| `CORTEXT_ASSETS_SHA256` | Override expected archive checksum |
| `CORTEXT_ASSET_CACHE_DIR` | Parent cache dir for downloaded versions |
| `CORTEXT_AIST_MODEL_PATH` | Optional explicit full `.gguf` (engine-side) |

## Develop

```bash
git clone https://github.com/augmem/cortext.dart.git
cd cortext.dart
dart pub get

# Option A: fetch release natives
./scripts/fetch_assets.sh
export CORTEXT_ASSETS_DIR="$HOME/Library/Caches/augmem/cortext/assets/1.2.4"  # macOS default

# Option B: monorepo engine checkout at ../cortext with ffi-release build

dart test
dart analyze
```

### Regenerate FFI bindings

Requires a local [augmem/cortext.cpp](https://github.com/augmem/cortext.cpp) checkout:

```bash
# from cortext.dart with ../cortext present
dart run ffigen --config ffigen.yaml
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
# 3) git tag v1.2.4 && git push origin v1.2.4
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
