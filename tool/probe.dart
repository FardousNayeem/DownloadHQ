// Manual check of engine.probe against arbitrary pages.
// dart run tool/probe.dart <bin-dir> <url>...
import 'dart:io';
import 'package:downloadhq/engine/desktop_tools.dart';
import 'package:downloadhq/engine/process_engine.dart';

Future<void> main(List<String> a) async {
  final engine = ProcessEngine(DesktopTools(a[0]));
  for (final url in a.skip(1)) {
    final sw = Stopwatch()..start();
    try {
      final r = await engine.probe(url);
      final e = r.entries.firstOrNull;
      stdout.writeln(
        'OK ${sw.elapsed.inMilliseconds}ms $url\n   "${r.title}" playlist=${r.isPlaylist} n=${r.entries.length}'
        ' first=${e?.id} "${e?.title}" dur=${e?.duration} h=${e?.heights} thumb=${e?.thumbnailUrl != null} url=${e?.url}',
      );
    } catch (err) {
      stdout.writeln('ERR ${sw.elapsed.inMilliseconds}ms $url: $err');
    }
  }
}
