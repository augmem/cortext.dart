import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'assets.dart';

const _aistRelative = 'AIST-87M-GGUF/AIST-87M_q8_0.gguf';
const _aistAltRelative = 'AIST-87M-GGUF/AIST-87M_q5_1.gguf';

typedef _SetenvNative =
    Int32 Function(Pointer<Utf8> name, Pointer<Utf8> value, Int32 overwrite);
typedef _SetenvDart =
    int Function(Pointer<Utf8> name, Pointer<Utf8> value, int overwrite);

typedef _UnsetenvNative = Int32 Function(Pointer<Utf8> name);
typedef _UnsetenvDart = int Function(Pointer<Utf8> name);

_SetenvDart? _setenv;
_UnsetenvDart? _unsetenv;
bool _envFnsResolved = false;

void _resolveEnvFns() {
  if (_envFnsResolved) {
    return;
  }
  _envFnsResolved = true;
  if (Platform.isWindows) {
    // Windows uses _putenv_s; release natives typically embed AIST.
    return;
  }
  try {
    final lib = DynamicLibrary.process();
    _setenv = lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv');
    _unsetenv = lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv');
  } on Object {
    _setenv = null;
    _unsetenv = null;
  }
}

/// Best-effort process env mutation for the native library's getenv.
bool setProcessEnv(String name, String value) {
  _resolveEnvFns();
  final setenv = _setenv;
  if (setenv == null) {
    return false;
  }
  final namePtr = name.toNativeUtf8();
  final valuePtr = value.toNativeUtf8();
  try {
    return setenv(namePtr, valuePtr, 1) == 0;
  } finally {
    malloc.free(namePtr);
    malloc.free(valuePtr);
  }
}

bool unsetProcessEnv(String name) {
  _resolveEnvFns();
  final unsetenv = _unsetenv;
  if (unsetenv == null) {
    return false;
  }
  final namePtr = name.toNativeUtf8();
  try {
    return unsetenv(namePtr) == 0;
  } finally {
    malloc.free(namePtr);
  }
}

const _aistEnv = 'CORTEXT_AIST_MODEL_PATH';
const _liEnv = 'CORTEXT_LI_MODEL_PATH';

/// File name of the AIST late-interaction reranker the engine loads beside the
/// AIST model (`AIST-87M-GGUF/AIST-87M-LI.gguf` in an assets tree).
const liModelFileName = 'AIST-87M-LI.gguf';
const _liRelative = 'AIST-87M-GGUF/$liModelFileName';

// Smallest file accepted as a model, so Git LFS pointers and truncated
// downloads are skipped. The reranker is ~400 KiB; AIST is ~140 MiB.
const _minAistBytes = 1024 * 1024;
const _minLiBytes = 4096;

/// Asset roots searched for on-disk models: `CORTEXT_ASSETS_DIR`, the resolved
/// release assets root, then the working directory and its ancestors (and a
/// sibling `cortext` engine checkout of each).
List<String> _modelSearchRoots(Map<String, String> environment) {
  final roots = <String>[];
  final assetsDir = environment['CORTEXT_ASSETS_DIR']?.trim();
  if (assetsDir != null && assetsDir.isNotEmpty) {
    roots.add(assetsDir);
  }
  if (CortextAssets.assetsDir != null) {
    roots.add(CortextAssets.assetsDir!);
  }
  var current = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    roots
      ..add(current.path)
      ..add(p.join(current.path, 'cortext'))
      ..add(p.join(current.path, '..', 'cortext'));
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  return roots;
}

String? _firstModel(Iterable<String> candidates, int minBytes) {
  for (final path in candidates) {
    final file = File(p.normalize(path));
    if (file.existsSync() && file.lengthSync() >= minBytes) {
      return file.absolute.path;
    }
  }
  return null;
}

/// Locate a full AIST `.gguf` on disk (not chunks).
///
/// `CORTEXT_AIST_MODEL_PATH` wins when it names an existing file; otherwise
/// the asset roots are searched. [environment] defaults to the process
/// environment.
String? findAistModelPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final pinned = env[_aistEnv]?.trim();
  if (pinned != null && pinned.isNotEmpty && File(pinned).existsSync()) {
    return pinned;
  }
  return _firstModel([
    for (final root in _modelSearchRoots(env)) ...[
      p.join(root, 'models', _aistRelative),
      p.join(root, 'models', _aistAltRelative),
      p.join(root, _aistRelative),
      p.join(root, _aistAltRelative),
    ],
  ], _minAistBytes);
}

/// Locate the AIST late-interaction reranker (`AIST-87M-LI.gguf`).
///
/// The engine requires it whenever an AIST model is in use. Resolution order
/// matches the engine: `CORTEXT_LI_MODEL_PATH` (null when set but missing, so
/// the engine reports that path), then [liModelFileName] beside
/// [aistModelPath], then the asset roots. [environment] defaults to the
/// process environment.
String? findLiModelPath({
  String? aistModelPath,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final pinned = env[_liEnv]?.trim();
  if (pinned != null && pinned.isNotEmpty) {
    return File(pinned).existsSync() ? pinned : null;
  }
  return _firstModel([
    if (aistModelPath != null)
      p.join(p.dirname(aistModelPath), liModelFileName),
    for (final root in _modelSearchRoots(env)) ...[
      p.join(root, 'models', _liRelative),
      p.join(root, _liRelative),
    ],
  ], _minLiBytes);
}

/// Points the native engine at on-disk models for `cortext_create`.
///
/// When the process does not pin `CORTEXT_AIST_MODEL_PATH` and a full GGUF is
/// found, that variable is set. When an AIST model is in use and
/// `CORTEXT_LI_MODEL_PATH` is unset, the reranker found by [findLiModelPath]
/// is pinned too, so an AIST model resolved from one root still finds a
/// reranker that lives in another. Returns the variables this call set; pass
/// them to [restoreModelEnv] after create so natives that embed the models
/// are not permanently shadowed.
List<String> ensureModelEnvForCreate() {
  final env = Platform.environment;
  final setNames = <String>[];
  var aist = env[_aistEnv]?.trim();
  if (aist == null || aist.isEmpty) {
    aist = findAistModelPath();
    if (aist == null) {
      return setNames; // embedded natives resolve both models themselves
    }
    if (setProcessEnv(_aistEnv, aist)) {
      setNames.add(_aistEnv);
    }
  }
  final pinnedLi = env[_liEnv]?.trim();
  if (pinnedLi == null || pinnedLi.isEmpty) {
    final li = findLiModelPath(aistModelPath: aist);
    if (li != null && setProcessEnv(_liEnv, li)) {
      setNames.add(_liEnv);
    }
  }
  return setNames;
}

/// Clears the variables [ensureModelEnvForCreate] set.
void restoreModelEnv(List<String> setNames) {
  for (final name in setNames) {
    unsetProcessEnv(name);
  }
}
