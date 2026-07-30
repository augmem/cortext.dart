import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform.dart';
import 'version.dart';

const _defaultAssetsRepo = 'augmem/cortext.cpp';
const _assetsMarkerName = '.cortext-assets-ok';

/// Resolves the unpacked assets root containing `native/` and `models/`.
///
/// Order:
/// 1. `CORTEXT_ASSETS_DIR` (pre-unpacked tree)
/// 2. Versioned user cache (download once from GitHub Releases if missing)
///
/// Override version with `CORTEXT_ASSETS_VERSION`, archive URL with
/// `CORTEXT_ASSETS_URL`, checksum with `CORTEXT_ASSETS_SHA256`, and cache
/// parent with `CORTEXT_ASSET_CACHE_DIR`.
class CortextAssets {
  CortextAssets._();

  static String? _cachedRoot;

  /// Last successful assets root, or null if not yet resolved.
  static String? get assetsDir => _cachedRoot;

  /// Default assets version string (no leading `v`).
  static String assetsVersion() {
    final env = Platform.environment['CORTEXT_ASSETS_VERSION']?.trim();
    if (env != null && env.isNotEmpty) {
      return env.startsWith('v') ? env.substring(1) : env;
    }
    return defaultAssetsVersion;
  }

  /// Ensures release assets are present and returns the root path.
  ///
  /// Uses `curl` + `tar` when a download is required (desktop/CI). For offline
  /// installs, pre-populate `CORTEXT_ASSETS_DIR` via `scripts/fetch_assets.sh`.
  static String ensure() {
    if (_cachedRoot != null) {
      final err = _validateRoot(_cachedRoot!);
      if (err == null) {
        return _cachedRoot!;
      }
      _cachedRoot = null;
    }
    final root = _ensureLocked();
    _cachedRoot = root;
    return root;
  }

  /// Native library path for the host under [assetsRoot].
  static String nativeLibraryPath(String assetsRoot) {
    final tag = platformTag();
    return p.join(assetsRoot, 'native', tag, libraryNameForTag(tag));
  }

  static String _ensureLocked() {
    final override = Platform.environment['CORTEXT_ASSETS_DIR']?.trim();
    if (override != null && override.isNotEmpty) {
      final abs = p.normalize(p.absolute(override));
      final err = _validateRoot(abs);
      if (err != null) {
        throw StateError('CORTEXT_ASSETS_DIR: $err');
      }
      return abs;
    }

    final version = assetsVersion();
    final root = _defaultCacheRoot(version);
    final marker = p.join(root, _assetsMarkerName);
    if (File(marker).existsSync() && _validateRoot(root) == null) {
      return root;
    }

    // Incomplete cache — rebuild.
    if (Directory(root).existsSync()) {
      Directory(root).deleteSync(recursive: true);
    }
    Directory(root).createSync(recursive: true);

    final url = _archiveUrl(version);
    final tmp = Directory.systemTemp.createTempSync('cortext-assets-');
    try {
      final archivePath = p.join(tmp.path, 'cortext-assets-$version.tar.gz');
      _download(url, archivePath);
      final wantSha = _resolveSha256(version, url);
      final gotSha = _fileSha256(archivePath);
      if (wantSha.isNotEmpty &&
          wantSha.toLowerCase() != gotSha.toLowerCase()) {
        throw StateError(
          'cortext assets checksum mismatch: got $gotSha want $wantSha',
        );
      }
      _extractTarGz(archivePath, root);
      final err = _validateRoot(root);
      if (err != null) {
        throw StateError(err);
      }
      File(marker).writeAsStringSync('$version\n');
      return root;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // best effort
      }
    }
  }

  static String _archiveUrl(String version) {
    final override = Platform.environment['CORTEXT_ASSETS_URL']?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    final name = 'cortext-assets-$version.tar.gz';
    return 'https://github.com/$_defaultAssetsRepo/releases/download/v$version/$name';
  }

  static String _defaultCacheRoot(String version) {
    final env = Platform.environment['CORTEXT_ASSET_CACHE_DIR']?.trim();
    if (env != null && env.isNotEmpty) {
      return p.join(p.normalize(p.absolute(env)), version);
    }
    return p.join(_userCacheBase(), 'augmem', 'cortext', 'assets', version);
  }

  static String _userCacheBase() {
    if (Platform.isWindows) {
      final local =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'];
      if (local != null && local.isNotEmpty) {
        return local;
      }
      return p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Local');
    }
    if (Platform.isMacOS) {
      return p.join(
        Platform.environment['HOME'] ?? Directory.current.path,
        'Library',
        'Caches',
      );
    }
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return xdg;
    }
    return p.join(Platform.environment['HOME'] ?? Directory.current.path, '.cache');
  }

  static String? _validateRoot(String root) {
    final nativeManifest = p.join(root, 'native', 'manifest.json');
    if (!File(nativeManifest).existsSync()) {
      return 'missing native/manifest.json under $root';
    }
    final lib = nativeLibraryPath(root);
    if (!File(lib).existsSync()) {
      return 'missing native library for ${platformTag()} at $lib';
    }
    final modelManifest = p.join(root, 'models', 'manifest.json');
    if (!File(modelManifest).existsSync()) {
      return 'missing models/manifest.json under $root';
    }
    return null;
  }

  static void _download(String url, String dest) {
    Directory(p.dirname(dest)).createSync(recursive: true);
    final result = Process.runSync('curl', ['-fsSL', '-o', dest, url], runInShell: false);
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw StateError(
        'download failed ($url): ${err.isEmpty ? 'exit ${result.exitCode}' : err}',
      );
    }
  }

  static String _resolveSha256(String version, String archiveUrl) {
    final override = Platform.environment['CORTEXT_ASSETS_SHA256']?.trim();
    if (override != null && override.isNotEmpty) {
      return override.toLowerCase();
    }
    final sumUrl = '$archiveUrl.sha256';
    final tmp = p.join(Directory.systemTemp.path, 'cortext-assets-$version.sha256');
    _download(sumUrl, tmp);
    final line = File(tmp).readAsStringSync().trim();
    if (line.isEmpty) {
      throw StateError('empty assets checksum from $sumUrl');
    }
    final fields = line.split(RegExp(r'\s+'));
    final sum = fields.first.toLowerCase();
    if (sum.length != 64) {
      throw StateError('invalid assets sha256 from $sumUrl: $sum');
    }
    return sum;
  }

  static String _fileSha256(String path) {
    // Prefer shasum/sha256sum for large archives without pulling crypto deps.
    if (Platform.isWindows) {
      final r = Process.runSync('certutil', ['-hashfile', path, 'SHA256']);
      if (r.exitCode == 0) {
        final lines = (r.stdout as String).split('\n');
        for (final line in lines) {
          final t = line.trim().toLowerCase().replaceAll(' ', '');
          if (RegExp(r'^[0-9a-f]{64}$').hasMatch(t)) {
            return t;
          }
        }
      }
    } else {
      ProcessResult r;
      if (Platform.isMacOS) {
        r = Process.runSync('shasum', ['-a', '256', path]);
      } else {
        r = Process.runSync('sha256sum', [path]);
      }
      if (r.exitCode == 0) {
        final out = (r.stdout as String).trim().split(RegExp(r'\s+')).first;
        return out.toLowerCase();
      }
    }
    throw StateError('could not hash $path');
  }

  static void _extractTarGz(String archive, String dest) {
    Directory(dest).createSync(recursive: true);
    final result = Process.runSync(
      'tar',
      ['-xzf', archive, '-C', dest],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw StateError(
        'extract failed: ${err.isEmpty ? 'exit ${result.exitCode}' : err}',
      );
    }
  }
}

/// Returns true when [root] looks like a complete assets tree for this host.
bool assetsRootReady(String root) {
  try {
    final manifest = File(p.join(root, 'native', 'manifest.json'));
    final lib = File(CortextAssets.nativeLibraryPath(root));
    final models = File(p.join(root, 'models', 'manifest.json'));
    return manifest.existsSync() && lib.existsSync() && models.existsSync();
  } on Object {
    return false;
  }
}

/// Parse a release `.sha256` line for tests / tooling.
String? parseSha256Line(String line) {
  final fields = line.trim().split(RegExp(r'\s+'));
  if (fields.isEmpty) {
    return null;
  }
  final sum = fields.first.toLowerCase();
  if (sum.length != 64) {
    return null;
  }
  return sum;
}

/// JSON helper for debugging asset resolution (not part of stable API).
Map<String, Object?> assetsDebugInfo() {
  return <String, Object?>{
    'platformTag': platformTag(),
    'assetsVersion': CortextAssets.assetsVersion(),
    'packageVersion': packageVersion,
    'assetsDir': CortextAssets.assetsDir,
    'env': <String, String?>{
      'CORTEXT_LIBRARY_PATH': Platform.environment['CORTEXT_LIBRARY_PATH'],
      'CORTEXT_ASSETS_DIR': Platform.environment['CORTEXT_ASSETS_DIR'],
      'CORTEXT_ASSETS_VERSION': Platform.environment['CORTEXT_ASSETS_VERSION'],
    },
  };
}

// Keep converter available for potential pure-dart checksum tests.
String jsonEncodeDebug(Object? value) => jsonEncode(value);
