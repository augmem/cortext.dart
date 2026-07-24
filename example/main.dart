import 'package:cortext/cortext.dart';

void main() {
  print('cortext package $packageVersion (assets $defaultAssetsVersion)');
  print('platform ${platformTag()}');

  final memory = Cortext(dbPath: ':memory:');
  try {
    print('engine ${memory.version()}');
    final ctx = memory.processText(
      'Bailey likes tennis balls.',
      'chat/main',
      const ProcessOptions(retention: Retention.durable),
    );
    print('consolidation_state=${ctx['consolidation_state']}');
    final emb = memory.embedText('embed without storing');
    print('embedding length=${emb.length}');
  } finally {
    memory.flush();
    memory.close();
  }
}
