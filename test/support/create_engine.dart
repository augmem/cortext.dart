// Opens and closes an in-memory engine; used by tests that need a fresh
// process environment (model path overrides are read at engine create).
import 'dart:io';

import 'package:cortext/cortext.dart';

void main() {
  try {
    final engine = Cortext(dbPath: ':memory:');
    engine.close();
    stdout.writeln('ok');
  } on Object catch (err) {
    stderr.writeln(err);
    exitCode = 3;
  }
}
