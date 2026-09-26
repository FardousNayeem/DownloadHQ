import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:downloadhq/data/json_store.dart';
import 'package:downloadhq/data/repositories.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('dhq_store'));
  tearDown(() => dir.delete(recursive: true));

  test('a failed write does not block later writes', () async {
    // Parent path is a file, so the first write cannot create its directory.
    final blocker = File('${dir.path}/blocked')..writeAsStringSync('x');
    final bad = JsonStore('${blocker.path}/lib.json');
    await bad.write({'a': 1}); // must not throw
    final good = JsonStore('${dir.path}/ok.json');
    await good.write({'a': 1});
    await good.write({'a': 2});
    expect(await good.read(), {'a': 2});
  });

  test('wrong-shaped library is set aside, not a crash', () async {
    final path = '${dir.path}/library.json';
    File(path).writeAsStringSync('{"playlists":[{"title":"no id or url"}]}');
    final repo = JsonLibraryRepository(JsonStore(path));
    expect(await repo.load(), isEmpty);
    expect(File(path).existsSync(), isFalse);
    expect(dir.listSync().any((f) => f.path.contains('library.json.corrupt-')), isTrue);
  });

  test('unparseable settings fall back to defaults', () async {
    final path = '${dir.path}/settings.json';
    File(path).writeAsStringSync('{"parallelDownloads":"lots"}');
    final s = await SettingsRepository(JsonStore(path), '/music').load();
    expect(s.downloadDir, '/music');
    expect(s.parallelDownloads, 2);
  });
}
