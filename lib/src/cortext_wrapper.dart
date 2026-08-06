import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'assets.dart';
import 'cortext_bindings.dart';
import 'model.dart';
import 'platform.dart';

final class CortextError implements Exception {
  const CortextError(this.message);

  final String message;

  @override
  String toString() => 'CortextError: $message';
}

@immutable
final class Config {
  const Config({
    this.focus = 0.5,
    this.sensitivity = 0.5,
    this.stability = 0.5,
    this.affectInterrupt = true,
    this.affectRetrieval = true,
    this.reinforcementEnabled = true,
    this.proceduralEnabled = true,
    this.sequentialEdgesEnabled = true,
    this.signalFilterAudioEnabled = true,
    this.signalFilterImageEnabled = true,
    this.signalFilterTextEnabled = false,
  });

  final double focus;
  final double sensitivity;
  final double stability;
  final bool affectInterrupt;
  final bool affectRetrieval;
  final bool reinforcementEnabled;
  final bool proceduralEnabled;
  final bool sequentialEdgesEnabled;
  final bool signalFilterAudioEnabled;
  final bool signalFilterImageEnabled;
  final bool signalFilterTextEnabled;
}

@immutable
final class Media {
  const Media({required this.data, required this.mimetype});

  final Uint8List data;
  final String mimetype;
}

@immutable
final class ProcessOptions {
  const ProcessOptions({
    this.includeEmbedding = true,
    this.retention = Retention.natural,
  });

  final bool includeEmbedding;
  final Retention retention;
}

enum Retention { natural, durable, boundary, ephemeral }

void _validateImageBuffer(Uint8List data, int width, int height, int channels) {
  if (width <= 0 || height <= 0 || channels <= 0) {
    throw ArgumentError('width, height, and channels must be positive');
  }
  if (width > 0x7fffffff || height > 0x7fffffff || channels > 0x7fffffff) {
    throw ArgumentError('image dimensions exceed the native int range');
  }
  final expected = width * height * channels;
  if (data.length < expected) {
    throw ArgumentError(
      'image buffer is smaller than width * height * channels',
    );
  }
}

final class CortextLibrary {
  CortextLibrary._(this.dynamicLibrary, {this.resolvedPath})
    : bindings = CortextBindings(dynamicLibrary);

  final DynamicLibrary dynamicLibrary;
  final CortextBindings bindings;

  /// Absolute path of the loaded library when known.
  final String? resolvedPath;

  /// Open the native library.
  ///
  /// Resolution order:
  /// 1. Explicit [libraryPath]
  /// 2. `CORTEXT_LIBRARY_PATH`
  /// 3. `CORTEXT_ASSETS_DIR` / package-vendored `native/<tag>/`
  /// 4. GitHub release assets via [CortextAssets.ensure] (download once)
  /// 5. Dev monorepo engine build outputs (`build/ffi-release`, `zig-out/lib`, …)
  /// 6. Bare system library name (`libcortext.dylib` / `.so` / `cortext.dll`)
  ///
  /// Release assets are preferred over monorepo outputs so a sibling engine
  /// checkout with an incomplete native does not shadow the official path.
  static CortextLibrary open({String? libraryPath, bool downloadAssets = true}) {
    if (libraryPath != null) {
      return _openPath(libraryPath);
    }

    final envPath = Platform.environment['CORTEXT_LIBRARY_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      return _openPath(envPath);
    }

    for (final candidate in candidateLibraryPaths(includeEngineBuilds: false)) {
      if (File(candidate).existsSync()) {
        return _openPath(candidate);
      }
    }

    Object? assetsError;
    if (downloadAssets) {
      try {
        final root = CortextAssets.ensure();
        final fromAssets = CortextAssets.nativeLibraryPath(root);
        if (File(fromAssets).existsSync()) {
          return _openPath(fromAssets);
        }
      } on Object catch (err) {
        assetsError = err;
      }
    }

    for (final candidate in candidateLibraryPaths(includeEngineBuilds: true)) {
      if (File(candidate).existsSync()) {
        return _openPath(candidate);
      }
    }

    for (final name in _libraryBasenamesForPlatform()) {
      try {
        return CortextLibrary._(DynamicLibrary.open(name), resolvedPath: name);
      } on ArgumentError {
        continue;
      }
    }

    final assetsDetail =
        assetsError == null ? '' : ' Asset resolution failed: $assetsError.';
    throw CortextError(
      'Could not locate the Cortext shared library for ${platformTag()}. '
      'Set CORTEXT_LIBRARY_PATH, CORTEXT_ASSETS_DIR, run scripts/fetch_assets.sh, '
      'or vendor natives under native/${platformTag()}/.$assetsDetail',
    );
  }

  static CortextLibrary _openPath(String path) {
    return CortextLibrary._(DynamicLibrary.open(path), resolvedPath: path);
  }

  String version() {
    final raw = bindings.cortext_version();
    return raw == nullptr ? '' : raw.cast<Utf8>().toDartString();
  }

  String lastError() {
    final raw = bindings.cortext_last_error();
    return raw == nullptr ? '' : raw.cast<Utf8>().toDartString();
  }

  /// Candidate absolute paths for the host native library.
  ///
  /// When [includeEngineBuilds] is false, only package/assets-style locations
  /// are returned (no monorepo `build/` / `zig-out/` paths).
  @visibleForTesting
  static List<String> candidateLibraryPaths({
    String? packageRoot,
    String? engineRoot,
    bool includeEngineBuilds = true,
  }) {
    final tag = platformTag();
    final libName = libraryNameForTag(tag);
    final paths = <String>[];

    void addFile(String path) {
      final normalized = p.normalize(path);
      if (!paths.contains(normalized)) {
        paths.add(normalized);
      }
    }

    // Explicit assets dir (without forcing download).
    final assetsDir = Platform.environment['CORTEXT_ASSETS_DIR']?.trim();
    if (assetsDir != null && assetsDir.isNotEmpty) {
      addFile(p.join(assetsDir, 'native', tag, libName));
    }

    final roots = <String>{
      if (packageRoot != null) packageRoot,
      ..._packageSearchRoots(),
    };

    for (final root in roots) {
      // Standalone package layout: native/<platform-tag>/libcortext.*
      addFile(p.join(root, 'native', tag, libName));
      // Optional flat package root
      addFile(p.join(root, libName));
    }

    if (!includeEngineBuilds) {
      return paths;
    }

    final engines = <String>{
      if (engineRoot != null) engineRoot,
      for (final root in roots) p.join(root, '..', 'cortext'),
      for (final root in roots) p.join(root, 'cortext'),
      ..._candidateSearchRoots(),
    };

    for (final root in engines) {
      final abs = p.normalize(root);
      for (final directory in <String>[
        p.join(abs, 'build', 'ffi-release'),
        p.join(abs, 'build', 'ffi-release', 'lib'),
        p.join(abs, 'zig-out', 'lib'),
        p.join(abs, 'install', 'lib'),
        p.join(abs, 'dist', 'release-assets', 'native', tag),
      ]) {
        addFile(p.join(directory, libName));
      }
    }

    return paths;
  }

  static List<String> _packageSearchRoots() {
    final roots = <String>{};
    void consider(String startingPath) {
      var current = Directory(startingPath).absolute;
      for (var i = 0; i < 10; i++) {
        final pubspec = File(p.join(current.path, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          try {
            final text = pubspec.readAsStringSync();
            if (RegExp(r'^name:\s*cortext\s*$', multiLine: true).hasMatch(text)) {
              roots.add(current.path);
            }
          } on Object {
            // ignore unreadable pubspec
          }
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }

    consider(Directory.current.path);
    if (Platform.script.scheme == 'file') {
      consider(File.fromUri(Platform.script).parent.path);
    }
    return roots.toList(growable: false);
  }

  static List<String> _candidateSearchRoots() {
    final roots = <String>{};
    void addAncestors(String startingPath) {
      var current = Directory(startingPath).absolute;
      while (true) {
        roots.add(current.path);
        final parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }

    addAncestors(Directory.current.path);
    if (Platform.script.scheme == 'file') {
      addAncestors(File.fromUri(Platform.script).parent.path);
    }
    return roots.toList(growable: false);
  }

  static List<String> _libraryBasenamesForPlatform() {
    if (Platform.isMacOS) {
      return const <String>['libcortext.dylib'];
    }
    if (Platform.isWindows) {
      return const <String>['cortext.dll', 'libcortext.dll'];
    }
    return const <String>['libcortext.so'];
  }
}

final class Cortext {
  Cortext({
    this.dbPath = ':memory:',
    this.config,
    String? libraryPath,
    CortextLibrary? library,
  }) : _library = library ?? CortextLibrary.open(libraryPath: libraryPath) {
    final nativeConfig = calloc<cortext_config>();
    Pointer<Utf8>? dbPathPointer;
    // Prefer an on-disk GGUF when present (monorepo / assets). Clear after
    // create so embedded release natives are not permanently shadowed.
    final previousModelEnv = ensureAistModelEnvForCreate();

    try {
      _library.bindings.cortext_config_init(nativeConfig);
      final configValue = config;
      if (configValue != null) {
        nativeConfig.ref
          ..focus = configValue.focus
          ..sensitivity = configValue.sensitivity
          ..stability = configValue.stability
          ..affect_interrupt = _boolToInt(configValue.affectInterrupt)
          ..affect_retrieval = _boolToInt(configValue.affectRetrieval)
          ..reinforcement_enabled = _boolToInt(configValue.reinforcementEnabled)
          ..procedural_enabled = _boolToInt(configValue.proceduralEnabled)
          ..sequential_edges_enabled = _boolToInt(
            configValue.sequentialEdgesEnabled,
          )
          ..signal_filter_audio_enabled = _boolToInt(
            configValue.signalFilterAudioEnabled,
          )
          ..signal_filter_image_enabled = _boolToInt(
            configValue.signalFilterImageEnabled,
          )
          ..signal_filter_text_enabled = _boolToInt(
            configValue.signalFilterTextEnabled,
          );
      }

      dbPathPointer = dbPath.toNativeUtf8();

      _handle = _library.bindings.cortext_create_with_config(
        nativeConfig,
        dbPathPointer.cast(),
      );
      if (_handle == nullptr) {
        _throwLastError('cortext_create_with_config failed');
      }
    } finally {
      restoreAistModelEnv(previousModelEnv);
      calloc.free(nativeConfig);
      if (dbPathPointer != null) {
        malloc.free(dbPathPointer);
      }
    }
  }

  final String dbPath;
  final Config? config;
  final CortextLibrary _library;
  Pointer<Void> _handle = nullptr;

  String version() => _library.version();

  String lastError() => _library.lastError();

  void close() {
    if (_handle == nullptr) {
      return;
    }
    _library.bindings.cortext_free(_handle);
    _handle = nullptr;
  }

  String processTextJson(
    String text,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    final optionsPointer = _allocateProcessOptions(options);
    return _withTwoStrings(
      text,
      sourceId,
      (textPointer, sourcePointer) =>
          _library.bindings.cortext_process_text_json_with_options(
            _handle,
            textPointer.cast(),
            sourcePointer.cast(),
            optionsPointer,
          ),
      after: () => malloc.free(optionsPointer),
    );
  }

  /// Processes text and persists an optional arbitrary binary media payload.
  ///
  /// [media] is copied by the native call. Its bytes are kept binary (they are
  /// not decoded as text), and [Media.mimetype] identifies their content type.
  String processTextWithMediaJson(
    String text,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    final textPointer = text.toNativeUtf8();
    final sourcePointer = sourceId.toNativeUtf8();
    final optionsPointer = _allocateProcessOptions(options);
    Pointer<cortext_media> mediaPointer = nullptr;
    Pointer<Uint8> mediaDataPointer = nullptr;
    Pointer<Utf8> mediaMimePointer = nullptr;
    try {
      if (media != null && media.data.isNotEmpty) {
        if (media.mimetype.isEmpty) {
          throw ArgumentError.value(
            media.mimetype,
            'media.mimetype',
            'must not be empty when media data is provided',
          );
        }
        // Allocate bytes as Uint8 rather than converting through a string so
        // arbitrary binary payloads, including embedded NUL bytes, survive.
        mediaDataPointer = malloc<Uint8>(media.data.length);
        mediaDataPointer.asTypedList(media.data.length).setAll(0, media.data);
        mediaMimePointer = media.mimetype.toNativeUtf8();
        mediaPointer = malloc<cortext_media>();
        mediaPointer.ref
          ..data = mediaDataPointer
          ..size = media.data.length
          ..mimetype = mediaMimePointer.cast();
      }
      final raw = _library.bindings
          .cortext_process_text_with_media_json_with_options(
            _handle,
            textPointer.cast(),
            sourcePointer.cast(),
            mediaPointer,
            optionsPointer,
          );
      return _takeJsonString(raw);
    } finally {
      malloc.free(textPointer);
      malloc.free(sourcePointer);
      malloc.free(optionsPointer);
      if (mediaPointer != nullptr) {
        malloc.free(mediaPointer);
      }
      if (mediaDataPointer != nullptr) {
        malloc.free(mediaDataPointer);
      }
      if (mediaMimePointer != nullptr) {
        malloc.free(mediaMimePointer);
      }
    }
  }

  Map<String, dynamic> processText(
    String text,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(processTextJson(text, sourceId, options));
  }

  Map<String, dynamic> processTextWithMedia(
    String text,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(
      processTextWithMediaJson(text, sourceId, media, options),
    );
  }

  String embedTextJson(String text) {
    _ensureOpen();
    final textPointer = text.toNativeUtf8();
    try {
      return _takeJsonString(
        _library.bindings.cortext_embed_text_json(_handle, textPointer.cast()),
      );
    } finally {
      malloc.free(textPointer);
    }
  }

  Float32List embedText(String text) {
    return _decodeEmbedding(embedTextJson(text));
  }

  String processAudioJson(
    Float32List pcm,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    final sourcePointer = sourceId.toNativeUtf8();
    final optionsPointer = _allocateProcessOptions(options);
    Pointer<Float> pcmPointer = nullptr;
    try {
      if (pcm.isNotEmpty) {
        pcmPointer = malloc<Float>(pcm.length);
        pcmPointer.asTypedList(pcm.length).setAll(0, pcm);
      }
      final raw = _library.bindings.cortext_process_audio_json_with_options(
        _handle,
        pcmPointer,
        pcm.length,
        sourcePointer.cast(),
        optionsPointer,
      );
      return _takeJsonString(raw);
    } finally {
      malloc.free(sourcePointer);
      malloc.free(optionsPointer);
      if (pcmPointer != nullptr) {
        malloc.free(pcmPointer);
      }
    }
  }

  String processAudioWithMediaJson(
    Float32List pcm,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    final sourcePointer = sourceId.toNativeUtf8();
    final optionsPointer = _allocateProcessOptions(options);
    Pointer<Float> pcmPointer = nullptr;
    Pointer<cortext_media> mediaPointer = nullptr;
    Pointer<Uint8> mediaDataPointer = nullptr;
    Pointer<Utf8> mediaMimePointer = nullptr;
    try {
      if (pcm.isNotEmpty) {
        pcmPointer = malloc<Float>(pcm.length);
        pcmPointer.asTypedList(pcm.length).setAll(0, pcm);
      }
      if (media != null && media.data.isNotEmpty) {
        if (media.mimetype.isEmpty) {
          throw ArgumentError.value(
            media.mimetype,
            'media.mimetype',
            'must not be empty when media data is provided',
          );
        }
        mediaDataPointer = malloc<Uint8>(media.data.length);
        mediaDataPointer.asTypedList(media.data.length).setAll(0, media.data);
        mediaMimePointer = media.mimetype.toNativeUtf8();
        mediaPointer = malloc<cortext_media>();
        mediaPointer.ref
          ..data = mediaDataPointer
          ..size = media.data.length
          ..mimetype = mediaMimePointer.cast();
      }
      final raw = _library.bindings
          .cortext_process_audio_with_media_json_with_options(
            _handle,
            pcmPointer,
            pcm.length,
            sourcePointer.cast(),
            mediaPointer,
            optionsPointer,
          );
      return _takeJsonString(raw);
    } finally {
      malloc.free(sourcePointer);
      malloc.free(optionsPointer);
      if (pcmPointer != nullptr) {
        malloc.free(pcmPointer);
      }
      if (mediaPointer != nullptr) {
        malloc.free(mediaPointer);
      }
      if (mediaDataPointer != nullptr) {
        malloc.free(mediaDataPointer);
      }
      if (mediaMimePointer != nullptr) {
        malloc.free(mediaMimePointer);
      }
    }
  }

  Map<String, dynamic> processAudio(
    Float32List pcm,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(processAudioJson(pcm, sourceId, options));
  }

  Map<String, dynamic> processAudioWithMedia(
    Float32List pcm,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(
      processAudioWithMediaJson(pcm, sourceId, media, options),
    );
  }

  String embedAudioJson(Float32List pcm) {
    _ensureOpen();
    Pointer<Float> pcmPointer = nullptr;
    try {
      if (pcm.isNotEmpty) {
        pcmPointer = malloc<Float>(pcm.length);
        pcmPointer.asTypedList(pcm.length).setAll(0, pcm);
      }
      final raw = _library.bindings.cortext_embed_audio_json(
        _handle,
        pcmPointer,
        pcm.length,
      );
      return _takeJsonString(raw);
    } finally {
      if (pcmPointer != nullptr) {
        malloc.free(pcmPointer);
      }
    }
  }

  Float32List embedAudio(Float32List pcm) {
    return _decodeEmbedding(embedAudioJson(pcm));
  }

  String processImageJson(
    Uint8List data,
    int width,
    int height,
    int channels,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    _validateImageBuffer(data, width, height, channels);
    final sourcePointer = sourceId.toNativeUtf8();
    final optionsPointer = _allocateProcessOptions(options);
    Pointer<Uint8> dataPointer = nullptr;
    try {
      if (data.isNotEmpty) {
        dataPointer = malloc<Uint8>(data.length);
        dataPointer.asTypedList(data.length).setAll(0, data);
      }
      final raw = _library.bindings.cortext_process_image_json_with_options(
        _handle,
        dataPointer,
        width,
        height,
        channels,
        sourcePointer.cast(),
        optionsPointer,
      );
      return _takeJsonString(raw);
    } finally {
      malloc.free(sourcePointer);
      malloc.free(optionsPointer);
      if (dataPointer != nullptr) {
        malloc.free(dataPointer);
      }
    }
  }

  String processImageWithMediaJson(
    Uint8List data,
    int width,
    int height,
    int channels,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    _ensureOpen();
    _validateImageBuffer(data, width, height, channels);
    final sourcePointer = sourceId.toNativeUtf8();
    final optionsPointer = _allocateProcessOptions(options);
    Pointer<Uint8> dataPointer = nullptr;
    Pointer<cortext_media> mediaPointer = nullptr;
    Pointer<Uint8> mediaDataPointer = nullptr;
    Pointer<Utf8> mediaMimePointer = nullptr;
    try {
      if (data.isNotEmpty) {
        dataPointer = malloc<Uint8>(data.length);
        dataPointer.asTypedList(data.length).setAll(0, data);
      }
      if (media != null && media.data.isNotEmpty) {
        if (media.mimetype.isEmpty) {
          throw ArgumentError.value(
            media.mimetype,
            'media.mimetype',
            'must not be empty when media data is provided',
          );
        }
        mediaDataPointer = malloc<Uint8>(media.data.length);
        mediaDataPointer.asTypedList(media.data.length).setAll(0, media.data);
        mediaMimePointer = media.mimetype.toNativeUtf8();
        mediaPointer = malloc<cortext_media>();
        mediaPointer.ref
          ..data = mediaDataPointer
          ..size = media.data.length
          ..mimetype = mediaMimePointer.cast();
      }
      final raw = _library.bindings
          .cortext_process_image_with_media_json_with_options(
            _handle,
            dataPointer,
            width,
            height,
            channels,
            sourcePointer.cast(),
            mediaPointer,
            optionsPointer,
          );
      return _takeJsonString(raw);
    } finally {
      malloc.free(sourcePointer);
      malloc.free(optionsPointer);
      if (dataPointer != nullptr) {
        malloc.free(dataPointer);
      }
      if (mediaPointer != nullptr) {
        malloc.free(mediaPointer);
      }
      if (mediaDataPointer != nullptr) {
        malloc.free(mediaDataPointer);
      }
      if (mediaMimePointer != nullptr) {
        malloc.free(mediaMimePointer);
      }
    }
  }

  Map<String, dynamic> processImage(
    Uint8List data,
    int width,
    int height,
    int channels,
    String sourceId, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(
      processImageJson(data, width, height, channels, sourceId, options),
    );
  }

  Map<String, dynamic> processImageWithMedia(
    Uint8List data,
    int width,
    int height,
    int channels,
    String sourceId,
    Media? media, [
    ProcessOptions options = const ProcessOptions(),
  ]) {
    return _decodeJsonObject(
      processImageWithMediaJson(
        data,
        width,
        height,
        channels,
        sourceId,
        media,
        options,
      ),
    );
  }

  String embedImageJson(Uint8List data, int width, int height, int channels) {
    _ensureOpen();
    _validateImageBuffer(data, width, height, channels);
    Pointer<Uint8> dataPointer = nullptr;
    try {
      if (data.isNotEmpty) {
        dataPointer = malloc<Uint8>(data.length);
        dataPointer.asTypedList(data.length).setAll(0, data);
      }
      final raw = _library.bindings.cortext_embed_image_json(
        _handle,
        dataPointer,
        width,
        height,
        channels,
      );
      return _takeJsonString(raw);
    } finally {
      if (dataPointer != nullptr) {
        malloc.free(dataPointer);
      }
    }
  }

  Float32List embedImage(Uint8List data, int width, int height, int channels) {
    return _decodeEmbedding(embedImageJson(data, width, height, channels));
  }

  String consolidateJson() {
    _ensureOpen();
    return _takeJsonString(_library.bindings.cortext_consolidate_json(_handle));
  }

  Map<String, dynamic> consolidate() {
    return _decodeJsonObject(consolidateJson());
  }

  void flush() {
    _ensureOpen();
    final status = _library.bindings.cortext_flush(_handle);
    if (status != 0) {
      _throwLastError('cortext_flush failed');
    }
  }

  void reset() {
    _ensureOpen();
    final status = _library.bindings.cortext_reset(_handle);
    if (status != 0) {
      _throwLastError('cortext_reset failed');
    }
  }

  String _withTwoStrings(
    String first,
    String second,
    Pointer<Char> Function(Pointer<Utf8> first, Pointer<Utf8> second) call, {
    void Function()? after,
  }) {
    final firstPointer = first.toNativeUtf8();
    final secondPointer = second.toNativeUtf8();
    try {
      return _takeJsonString(call(firstPointer, secondPointer));
    } finally {
      malloc.free(firstPointer);
      malloc.free(secondPointer);
      after?.call();
    }
  }

  Pointer<cortext_process_json_options> _allocateProcessOptions(
    ProcessOptions options,
  ) {
    final pointer = malloc<cortext_process_json_options>();
    pointer.ref
      ..struct_size = sizeOf<cortext_process_json_options>()
      ..include_embedding = options.includeEmbedding ? 1 : 0
      ..retention = options.retention.index
      ..reserved = 0;
    return pointer;
  }

  String _takeJsonString(Pointer<Char> raw) {
    if (raw == nullptr) {
      _throwLastError('cortext call failed');
    }
    try {
      return raw.cast<Utf8>().toDartString();
    } finally {
      _library.bindings.cortext_string_free(raw);
    }
  }

  Map<String, dynamic> _decodeJsonObject(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const CortextError('Expected a JSON object from cortext');
    }
    final map = Map<String, dynamic>.from(decoded);
    return _normalizeContext(map);
  }

  /// Public API always exposes `consolidation_state`.
  /// Older natives only had boolean recommended/required flags.
  Map<String, dynamic> _normalizeContext(Map<String, dynamic> raw) {
    if (raw['consolidation_state'] is String) {
      return raw;
    }
    var state = 'none';
    if (raw['consolidation_required'] == true) {
      state = 'required';
    } else if (raw['consolidation_recommended'] == true) {
      state = 'recommended';
    }
    return <String, dynamic>{...raw, 'consolidation_state': state};
  }

  Float32List _decodeEmbedding(String payload) {
    final decoded = _decodeJsonObject(payload);
    final values = decoded['embedding'];
    if (values is! List) {
      throw const CortextError('Expected an embedding array from cortext');
    }
    return Float32List.fromList([
      for (final value in values) (value as num).toDouble(),
    ]);
  }

  Never _throwLastError(String prefix) {
    final detail = lastError();
    throw CortextError(detail.isEmpty ? prefix : '$prefix: $detail');
  }

  void _ensureOpen() {
    if (_handle == nullptr) {
      throw const CortextError('Cortext handle is closed');
    }
  }

  int _boolToInt(bool value) => value ? 1 : 0;
}
