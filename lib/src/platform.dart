import 'dart:io';

/// Host platform tags matching release asset layout under `native/<tag>/`.
const supportedNativeTargets = <String>{
  'linux-aarch64',
  'linux-x86_64',
  'macos-aarch64',
  'macos-x86_64',
  'windows-aarch64',
  'windows-x86_64',
};

/// e.g. `macos-aarch64`, `linux-x86_64`.
String platformTag() {
  final String osTag;
  if (Platform.isMacOS) {
    osTag = 'macos';
  } else if (Platform.isLinux) {
    osTag = 'linux';
  } else if (Platform.isWindows) {
    osTag = 'windows';
  } else {
    osTag = Platform.operatingSystem;
  }
  return '$osTag-${_cpuArch()}';
}

String _cpuArch() {
  if (Platform.isWindows) {
    final env =
        Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase() ?? '';
    if (env.contains('arm64') || env == 'aarch64') {
      return 'aarch64';
    }
    return 'x86_64';
  }

  try {
    final result = Process.runSync('uname', ['-m']);
    if (result.exitCode == 0) {
      final m = (result.stdout as String).trim().toLowerCase();
      if (m == 'arm64' || m == 'aarch64') {
        return 'aarch64';
      }
      if (m == 'x86_64' || m == 'amd64') {
        return 'x86_64';
      }
      if (m.isNotEmpty) {
        return m;
      }
    }
  } on Object {
    // fall through
  }

  // Default: modern macOS Dart installs are arm64; Linux CI is usually x86_64.
  if (Platform.isMacOS) {
    return 'aarch64';
  }
  return 'x86_64';
}

String libraryNameForTag(String tag) {
  final osTag = tag.split('-').first;
  if (osTag == 'macos') {
    return 'libcortext.dylib';
  }
  if (osTag == 'windows') {
    return 'cortext.dll';
  }
  return 'libcortext.so';
}

String hostLibraryName() => libraryNameForTag(platformTag());
