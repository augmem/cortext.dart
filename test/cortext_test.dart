import 'dart:convert';
import 'dart:io';
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

    test('mixed memory returns every payload with its MIME type', () {
      final dir = Directory.systemTemp.createTempSync('cortext_mixed_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = Cortext(dbPath: '${dir.path}/mixed.db');
      addTearDown(engine.close);
      final photo = Uint8List.fromList(
        <int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9],
      );
      // One turn = one source: a text signal and its photo, as peers.
      engine.processText(
        'The parking garage ticket says level 4 spot 27.',
        'chat/user/turn1',
        const ProcessOptions(retention: Retention.natural),
      );
      engine.processImageWithMedia(
        Uint8List(8 * 8 * 3)..fillRange(0, 8 * 8 * 3, 128),
        8,
        8,
        3,
        'chat/user/turn1',
        Media(data: photo, mimetype: 'image/jpeg'),
        const ProcessOptions(retention: Retention.durable),
      );
      final ctx = engine.processText(
        'parking garage level spot',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final memories = <Map<String, dynamic>>[
        for (final m in [
          ...ctx['retrieved_memory'] as List,
          ...ctx['working_memory'] as List,
        ])
          Map<String, dynamic>.from(m as Map),
      ];
      final mixed = memories.where((m) => m['modality'] == 'mixed').toList();
      expect(mixed, isNotEmpty);
      for (final memory in mixed) {
        final content = [
          for (final c in memory['content'] as List)
            Map<String, dynamic>.from(c as Map),
        ];
        expect(
          content.map((c) => c['mimetype']),
          unorderedEquals(<String>['text/plain', 'image/jpeg']),
        );
        final image = content.firstWhere((c) => c['mimetype'] == 'image/jpeg');
        expect(base64Decode(image['base64'] as String), orderedEquals(photo));
      }
    });

    test('an evidence budget bounds standing and retrieved memory', () {
      final dir = Directory.systemTemp.createTempSync('cortext_budget_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = Cortext(dbPath: '${dir.path}/budget.db');
      addTearDown(engine.close);
      const durable = ProcessOptions(retention: Retention.durable);
      engine.processText(
        'Always answer with the departure pier.',
        'chat/rules',
        durable,
      );
      for (var i = 0; i < 6; i++) {
        engine.processText(
          'The ferry to the island leaves at ${6 + i} from pier four.',
          'chat/ferry/$i',
          durable,
        );
      }
      int evidence(Map<String, dynamic> ctx) {
        var bytes = 0;
        for (final key in ['standing_memory', 'retrieved_memory']) {
          for (final m in ctx[key] as List) {
            for (final c in (m as Map)['content'] as List) {
              final content = c as Map;
              bytes += (content['mimetype'] as String).startsWith('text/')
                  ? content['size_bytes'] as int
                  : 480;
            }
          }
        }
        return bytes;
      }

      const query = 'When does the ferry leave?';
      final whole = engine.processText(
        query,
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final wholeCount = (whole['retrieved_memory'] as List).length;
      expect(wholeCount, greaterThanOrEqualTo(2));
      final budget = evidence(whole) ~/ 2;
      final budgeted = engine.processText(
        query,
        'query/public',
        ProcessOptions(
          retention: Retention.ephemeral,
          evidenceBudgetBytes: budget,
        ),
      );
      expect(evidence(budgeted), lessThanOrEqualTo(budget));
      expect(
        (budgeted['retrieved_memory'] as List).length,
        lessThan(wholeCount),
      );
      expect(
        () => engine.processText(
          query,
          'query/public',
          const ProcessOptions(evidenceBudgetBytes: 0),
        ),
        throwsArgumentError,
      );
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
