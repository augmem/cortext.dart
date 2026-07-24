import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'assets.dart';

const _aistRelative = 'AIST-87M-GGUF/AIST-87M_q8_0.gguf';
const _aistAltRelative = 'AIST-87M-GGUF/AIST-87M_q5_1.gguf';

typedef _SetenvNative = Int32 Function(
  Pointer<Utf8> name,
  Pointer<Utf8> value,
  Int32 overwrite,
);
typedef _SetenvDart = int Function(
  Pointer<Utf8> name,
  Pointer<Utf8> value,
  int overwrite,
);

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

/// Locate a full AIST `.gguf` on disk (not chunks).
String? findAistModelPath() {
  final env = Platform.environment['CORTEXT_AIST_MODEL_PATH']?.trim();
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return env;
  }

  final candidates = <String>[];

  void addRoot(String root) {
    candidates
      ..add(p.join(root, 'models', _aistRelative))
      ..add(p.join(root, 'models', _aistAltRelative))
      ..add(p.join(root, _aistRelative))
      ..add(p.join(root, _aistAltRelative));
  }

  final assetsDir = Platform.environment['CORTEXT_ASSETS_DIR']?.trim();
  if (assetsDir != null && assetsDir.isNotEmpty) {
    addRoot(assetsDir);
  }
  if (CortextAssets.assetsDir != null) {
    addRoot(CortextAssets.assetsDir!);
  }

  // Package / monorepo walk from cwd
  var current = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    addRoot(current.path);
    addRoot(p.join(current.path, 'cortext'));
    addRoot(p.join(current.path, '..', 'cortext'));
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }

  for (final path in candidates) {
    final file = File(p.normalize(path));
    if (file.existsSync() && file.lengthSync() > 1024 * 1024) {
      return file.absolute.path;
    }
  }
  return null;
}

/// If the process does not already pin `CORTEXT_AIST_MODEL_PATH`, set it when a
/// full GGUF is available. Returns the previous value (null if unset) so callers
/// can restore after create — release natives that embed AIST should not keep
/// a shadow path permanently.
String? ensureAistModelEnvForCreate() {
  final existing = Platform.environment['CORTEXT_AIST_MODEL_PATH'];
  if (existing != null && existing.isNotEmpty) {
    return existing; // already set; do not restore
  }
  final found = findAistModelPath();
  if (found == null) {
    return null;
  }
  if (setProcessEnv('CORTEXT_AIST_MODEL_PATH', found)) {
    return ''; // marker: we set it and should clear after
  }
  return null;
}

void restoreAistModelEnv(String? previous) {
  if (previous == null) {
    return;
  }
  if (previous.isEmpty) {
    unsetProcessEnv('CORTEXT_AIST_MODEL_PATH');
  } else {
    setProcessEnv('CORTEXT_AIST_MODEL_PATH', previous);
  }
}
