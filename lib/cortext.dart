/// Dart FFI bindings for the Cortext memory engine.
///
/// Package root: https://github.com/augmem/cortext.dart
/// Engine: https://github.com/augmem/cortext
library;

export 'src/assets.dart' show CortextAssets, assetsRootReady, assetsDebugInfo;
export 'src/model.dart' show findAistModelPath;
export 'src/platform.dart'
    show platformTag, supportedNativeTargets, hostLibraryName, libraryNameForTag;
export 'src/version.dart' show packageVersion, defaultAssetsVersion;
export 'src/cortext_wrapper.dart';
