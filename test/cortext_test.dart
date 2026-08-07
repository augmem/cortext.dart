import 'dart:typed_data';

import 'package:cortext/cortext.dart';
import 'package:test/test.dart';

void main() {
  group('library path candidates', () {
    test('include package native and monorepo-style engine outputs', () {
      final paths = CortextLibrary.candidateLibraryPaths(
        packageRoot: '/tmp/cortext.dart',
        engineRoot: '/tmp/cortext',
      );
      final tag = platformTag();
      final name = libraryNameForTag(tag);

      expect(
        paths.any(
          (p) => p.replaceAll(r'\', '/').endsWith('native/$tag/$name'),
        ),
        isTrue,
        reason: 'expected package native path among $paths',
      );
      expect(
        paths.any(
          (p) {
            final n = p.replaceAll(r'\', '/');
            return n.contains('build/ffi-release') && n.endsWith(name);
          },
        ),
        isTrue,
      );
      expect(
        paths.any(
          (p) {
            final n = p.replaceAll(r'\', '/');
            return n.contains('zig-out/lib') && n.endsWith(name);
          },
        ),
        isTrue,
      );
    });

    test('platformTag is a supported release target on desktop hosts', () {
      final tag = platformTag();
      expect(supportedNativeTargets.contains(tag), isTrue, reason: 'tag=$tag');
    });
  });

  group('native engine (integration)', () {
    Cortext? engine;

    setUpAll(() {
      // Prefer package-vendored natives, CORTEXT_ASSETS_DIR, or release download.
      engine = Cortext(dbPath: ':memory:');
    });

    tearDownAll(() {
      engine?.close();
    });

    test('version is non-empty', () {
      expect(engine!.version(), isNotEmpty);
    });

    test('processText exposes consolidation_state', () {
      final ctx = engine!.processText(
        'Dart binding consolidation-state contract probe.',
        'contract/runtime',
        const ProcessOptions(
          includeEmbedding: false,
          retention: Retention.ephemeral,
        ),
      );
      expect(ctx['consolidation_state'], isA<String>());
      expect(
        <String>['none', 'recommended', 'required'],
        contains(ctx['consolidation_state']),
      );
    });

    test('exposes text media process APIs', () {
      // Tear-offs verify the public API without requiring a new native symbol
      // from older release assets used by compatibility tests.
      expect(engine!.processTextWithMedia, isA<Function>());
      expect(engine!.processTextWithMediaJson, isA<Function>());
    });

    test('durable process then embedText', () {
      engine!.processText(
        'Bailey likes tennis balls.',
        'chat/main',
        const ProcessOptions(retention: Retention.durable),
      );
      final emb = engine!.embedText('embed without storing');
      expect(emb, isNotEmpty);
    });

    test('flush and reset succeed', () {
      engine!.flush();
      engine!.reset();
    });
  });

  group('media payloads', () {
    test('accept arbitrary binary bytes with a MIME type', () {
      final media = Media(
        data: Uint8List.fromList(<int>[0, 1, 255, 0, 42]),
        mimetype: 'application/octet-stream',
      );
      expect(media.data, orderedEquals(<int>[0, 1, 255, 0, 42]));
      expect(media.mimetype, 'application/octet-stream');
    });

    test('rejects media data without a MIME type before native', () {
      final engine = Cortext(dbPath: ':memory:');
      addTearDown(engine.close);
      expect(
        () => engine.processTextWithMediaJson(
          'text with invalid media',
          'media/validation',
          Media(data: Uint8List.fromList(<int>[1]), mimetype: ''),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('image validation', () {
    test('rejects undersized buffers before native', () {
      final engine = Cortext(dbPath: ':memory:');
      addTearDown(engine.close);
      expect(
        () => engine.processImage(
          Uint8List(3),
          2,
          2,
          3,
          'img',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
