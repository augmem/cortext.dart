import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cortext/cortext.dart';
import 'package:path/path.dart' as p;
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
        paths.any((p) => p.replaceAll(r'\', '/').endsWith('native/$tag/$name')),
        isTrue,
        reason: 'expected package native path among $paths',
      );
      expect(
        paths.any((p) {
          final n = p.replaceAll(r'\', '/');
          return n.contains('build/ffi-release') && n.endsWith(name);
        }),
        isTrue,
      );
      expect(
        paths.any((p) {
          final n = p.replaceAll(r'\', '/');
          return n.contains('zig-out/lib') && n.endsWith(name);
        }),
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
      expect(<String>[
        'none',
        'recommended',
        'required',
      ], contains(ctx['consolidation_state']));
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
      final photo = Uint8List.fromList(<int>[
        0xff,
        0xd8,
        0xff,
        0xe0,
        1,
        2,
        3,
        0xff,
        0xd9,
      ]);
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
        () => engine.processImage(Uint8List(3), 2, 2, 3, 'img'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('text with caller media', () {
    late Directory dir;
    late Cortext engine;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cortext_text_media_');
      engine = Cortext(dbPath: p.join(dir.path, 'media.db'));
    });

    tearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });

    test('stores binary media in place of the text and recalls it', () {
      final png = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        0,
        1,
        2,
        255,
      ]);
      engine.processTextWithMedia(
        'Receipt for the blue enamel kettle bought at the harbour market.',
        'chat/receipts',
        Media(data: png, mimetype: 'image/png'),
        const ProcessOptions(retention: Retention.durable),
      );
      final ctx = engine.processText(
        'blue enamel kettle receipt harbour market',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final memory = _allMemories(ctx).firstWhere(
        (m) => _contents(m).any((c) => c['mimetype'] == 'image/png'),
        orElse: () => fail('no memory carried the image/png payload: $ctx'),
      );
      expect(memory['mimetype'], 'image/png');
      final content = _contents(
        memory,
      ).firstWhere((c) => c['mimetype'] == 'image/png');
      expect(base64Decode(content['base64'] as String), orderedEquals(png));
    });

    test('text/* media is stored as the text payload', () {
      const markdown = '# Kettle\n\nBlue enamel, harbour market, 12 euro.';
      engine.processTextWithMedia(
        'Kettle note: blue enamel from the harbour market.',
        'chat/notes',
        Media(
          data: Uint8List.fromList(utf8.encode(markdown)),
          mimetype: 'text/markdown',
        ),
        const ProcessOptions(retention: Retention.durable),
      );
      final ctx = engine.processText(
        'blue enamel kettle harbour market note',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final content = _allMemories(ctx)
          .expand(_contents)
          .firstWhere(
            (c) => c['mimetype'] == 'text/markdown',
            orElse: () => fail('no text/markdown payload recalled: $ctx'),
          );
      expect(utf8.decode(base64Decode(content['base64'] as String)), markdown);
    });

    test('null or empty media stores the canonical text', () {
      const text = 'The lighthouse keeper feeds the gulls at dawn.';
      engine.processTextWithMedia(
        text,
        'chat/lighthouse',
        null,
        const ProcessOptions(retention: Retention.durable),
      );
      const emptyMediaText = 'The lighthouse lamp is serviced every spring.';
      engine.processTextWithMedia(
        emptyMediaText,
        'chat/lighthouse-2',
        Media(data: Uint8List(0), mimetype: 'image/png'),
        const ProcessOptions(retention: Retention.durable),
      );
      final ctx = engine.processText(
        'lighthouse keeper gulls lamp',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final contents = _allMemories(ctx).expand(_contents).toList();
      expect(contents, isNotEmpty);
      for (final c in contents) {
        expect(c['mimetype'], 'text/plain');
      }
      expect(
        contents.map((c) => utf8.decode(base64Decode(c['base64'] as String))),
        containsAll(<String>[text, emptyMediaText]),
      );
    });

    test('a query with media honours the evidence budget', () {
      final jpeg = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0, 9, 0xff]);
      for (var i = 0; i < 4; i++) {
        engine.processTextWithMedia(
          'Photo $i of the tide pool by the north jetty.',
          'chat/tide/$i',
          Media(data: jpeg, mimetype: 'image/jpeg'),
          const ProcessOptions(retention: Retention.durable),
        );
      }
      final whole = engine.processTextWithMedia(
        'tide pool north jetty photo',
        'query/public',
        null,
        const ProcessOptions(retention: Retention.ephemeral),
      );
      expect(whole['retrieved_memory'], isNotEmpty);
      expect(_evidenceBytes(whole), greaterThan(2 * mediaEvidenceBytes));
      const budget = 2 * mediaEvidenceBytes;
      final ctx = engine.processTextWithMedia(
        'tide pool north jetty photo',
        'query/public',
        null,
        const ProcessOptions(
          retention: Retention.ephemeral,
          evidenceBudgetBytes: budget,
        ),
      );
      expect(_evidenceBytes(ctx), lessThanOrEqualTo(budget));
      expect(ctx['retrieved_memory'], isNotEmpty);
    });
  });

  group('standing memory', () {
    test('a query returns directives in their own block; writes do not', () {
      final dir = Directory.systemTemp.createTempSync('cortext_standing_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = Cortext(dbPath: p.join(dir.path, 'standing.db'));
      addTearDown(engine.close);
      const durable = ProcessOptions(retention: Retention.durable);
      const directive = 'Always reply in British English.';
      final write = engine.processText(directive, 'chat/rules', durable);
      expect(write['standing_memory'], isEmpty);
      engine.processText(
        'The bakery on Mill Lane opens at seven.',
        'chat/bakery',
        durable,
      );
      final ctx = engine.processText(
        'When does the bakery open?',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final standing = [
        for (final m in ctx['standing_memory'] as List)
          Map<String, dynamic>.from(m as Map),
      ];
      expect(standing, isNotEmpty);
      expect(
        standing
            .expand(_contents)
            .map((c) => utf8.decode(base64Decode(c['base64'] as String))),
        contains(directive),
      );
      expect(ctx['retrieved_memory'], isA<List>());
    });
  });

  group('whole memories', () {
    test('long memories are not trimmed without an evidence budget', () {
      final dir = Directory.systemTemp.createTempSync('cortext_whole_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = Cortext(dbPath: p.join(dir.path, 'whole.db'));
      addTearDown(engine.close);
      final buffer = StringBuffer('Packing list for the glacier trek: ');
      for (var i = 0; buffer.length < 5000; i++) {
        buffer.write('item $i is a spare pair of wool socks, ');
      }
      final text = buffer.toString();
      engine.processText(
        text,
        'chat/packing',
        const ProcessOptions(retention: Retention.durable),
      );
      final ctx = engine.processText(
        'glacier trek packing list wool socks',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final content = _allMemories(ctx)
          .where((m) => m['source_id'] == 'chat/packing')
          .expand(_contents)
          .toList();
      expect(content, isNotEmpty);
      expect(
        content.map((c) => utf8.decode(base64Decode(c['base64'] as String))),
        contains(text),
      );
    });
  });

  group('per-content timestamps', () {
    test('every content blob carries its stored signal time in ms', () {
      final dir = Directory.systemTemp.createTempSync('cortext_ts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = Cortext(dbPath: p.join(dir.path, 'ts.db'));
      addTearDown(engine.close);
      final before = DateTime.now().millisecondsSinceEpoch;
      engine.processText(
        'The allotment shed key hangs behind the blue door.',
        'chat/shed',
        const ProcessOptions(retention: Retention.durable),
      );
      final after = DateTime.now().millisecondsSinceEpoch;
      final ctx = engine.processText(
        'Where is the allotment shed key?',
        'query/public',
        const ProcessOptions(retention: Retention.ephemeral),
      );
      final contents = _allMemories(
        ctx,
      ).where((m) => m['source_id'] == 'chat/shed').expand(_contents).toList();
      expect(contents, isNotEmpty);
      for (final c in contents) {
        expect(c['timestamp'], isA<int>());
        expect(c['timestamp'], inInclusiveRange(before, after));
      }
    });
  });

  group('reference-time retrieval', () {
    late Directory dir;
    late Cortext engine;
    const query = 'Which platform does the night train leave from?';

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cortext_reftime_');
      engine = Cortext(dbPath: p.join(dir.path, 'reftime.db'));
      for (var i = 0; i < 3; i++) {
        engine.processText(
          'The night train to the coast leaves from platform ${4 + i}.',
          'chat/train/$i',
          const ProcessOptions(retention: Retention.durable),
        );
      }
    });

    tearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });

    // Long-term recall (standing + retrieved); working memory is the live
    // conversation and is not filtered by a reference time.
    Set<Object?> recalledTrainSources(ProcessOptions options) {
      final ctx = engine.processText(query, 'query/public', options);
      return {
        for (final key in ['standing_memory', 'retrieved_memory'])
          for (final m in ctx[key] as List)
            if (((m as Map)['source_id'] as String).startsWith('chat/train/'))
              m['source_id'],
      };
    }

    List<Object?> retrieved(ProcessOptions options) =>
        engine.processText(query, 'query/public', options)['retrieved_memory']
            as List;

    test('without asOf keeps retrieval of memories stored after T', () {
      final past = DateTime.utc(2001, 1, 1);
      expect(
        retrieved(const ProcessOptions(retention: Retention.ephemeral)),
        isNotEmpty,
      );
      expect(
        retrieved(
          ProcessOptions(retention: Retention.ephemeral, referenceTime: past),
        ),
        isNotEmpty,
      );
    });

    test('asOf hides memories stored after the reference time', () {
      final past = DateTime.utc(2001, 1, 1);
      expect(
        recalledTrainSources(
          ProcessOptions(
            retention: Retention.ephemeral,
            referenceTime: past,
            asOf: true,
          ),
        ),
        isEmpty,
      );
      final future = DateTime.now().add(const Duration(hours: 1));
      expect(
        retrieved(
          ProcessOptions(
            retention: Retention.ephemeral,
            referenceTime: future,
            asOf: true,
          ),
        ),
        isNotEmpty,
      );
    });

    test('rejects asOf without a reference time and non-query calls', () {
      expect(
        () => engine.processText(
          query,
          'query/public',
          const ProcessOptions(retention: Retention.ephemeral, asOf: true),
        ),
        throwsArgumentError,
      );
      expect(
        () => engine.processText(
          query,
          'query/public',
          ProcessOptions(
            retention: Retention.durable,
            referenceTime: DateTime.utc(2001),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => engine.processText(
          query,
          'query/public',
          ProcessOptions(
            retention: Retention.ephemeral,
            referenceTime: DateTime.utc(1970),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('late-interaction model resolution', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cortext_li_');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    File writeModel(String path, int bytes) {
      final file = File(path)..createSync(recursive: true);
      file.writeAsBytesSync(Uint8List(bytes));
      return file;
    }

    test('CORTEXT_LI_MODEL_PATH wins when it exists', () {
      final li = writeModel(p.join(dir.path, 'custom', 'li.gguf'), 8192);
      expect(
        findLiModelPath(environment: {'CORTEXT_LI_MODEL_PATH': li.path}),
        li.path,
      );
    });

    test('a CORTEXT_LI_MODEL_PATH that does not exist resolves to null', () {
      writeModel(
        p.join(dir.path, 'models', 'AIST-87M-GGUF', liModelFileName),
        8192,
      );
      expect(
        findLiModelPath(
          environment: {
            'CORTEXT_LI_MODEL_PATH': p.join(dir.path, 'missing.gguf'),
            'CORTEXT_ASSETS_DIR': dir.path,
          },
        ),
        isNull,
      );
    });

    test('resolves the reranker beside the AIST model', () {
      final aist = p.join(dir.path, 'gguf', 'AIST-87M_q8_0.gguf');
      writeModel(aist, 8192);
      final li = writeModel(p.join(dir.path, 'gguf', liModelFileName), 8192);
      expect(
        findLiModelPath(aistModelPath: aist, environment: const {}),
        li.path,
      );
    });

    test('resolves the reranker from an assets tree', () {
      final li = writeModel(
        p.join(dir.path, 'models', 'AIST-87M-GGUF', liModelFileName),
        8192,
      );
      expect(
        findLiModelPath(environment: {'CORTEXT_ASSETS_DIR': dir.path}),
        li.absolute.path,
      );
    });

    test(
      'a missing pinned reranker fails engine creation',
      () async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', p.join('test', 'support', 'create_engine.dart')],
          environment: {
            'CORTEXT_LI_MODEL_PATH': p.join(
              dir.path,
              'missing',
              liModelFileName,
            ),
          },
        );
        expect(result.exitCode, 3, reason: '${result.stdout}${result.stderr}');
        expect(result.stderr, contains('late-interaction model not found'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('the test environment resolves AIST and its reranker', () {
      final aist = findAistModelPath();
      final li = findLiModelPath(aistModelPath: aist);
      if (aist != null) {
        expect(li, isNotNull, reason: 'AIST at $aist needs AIST-87M-LI.gguf');
      }
      final engine = Cortext(dbPath: ':memory:');
      addTearDown(engine.close);
      expect(engine.embedText('reranker smoke'), isNotEmpty);
    });
  });
}

List<Map<String, dynamic>> _allMemories(Map<String, dynamic> ctx) => [
  for (final key in ['standing_memory', 'retrieved_memory', 'working_memory'])
    for (final m in (ctx[key] as List?) ?? const [])
      Map<String, dynamic>.from(m as Map),
];

List<Map<String, dynamic>> _contents(Map<String, dynamic> memory) => [
  for (final c in memory['content'] as List)
    Map<String, dynamic>.from(c as Map),
];

int _evidenceBytes(Map<String, dynamic> ctx) {
  var bytes = 0;
  for (final key in ['standing_memory', 'retrieved_memory']) {
    for (final m in ctx[key] as List) {
      for (final c in _contents(Map<String, dynamic>.from(m as Map))) {
        bytes += (c['mimetype'] as String).startsWith('text/')
            ? c['size_bytes'] as int
            : mediaEvidenceBytes;
      }
    }
  }
  return bytes;
}
