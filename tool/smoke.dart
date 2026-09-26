// Manual end-to-end check of the desktop engine against live YouTube.
// dart run tool/smoke.dart <workdir> <playlist-url>
import 'dart:io';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/engine/desktop_tools.dart';
import 'package:downloadhq/engine/engine.dart';
import 'package:downloadhq/engine/process_engine.dart';

Future<void> main(List<String> a) async {
  final tools = DesktopTools('${a[0]}/bin');
  for (final t in Tool.values) {
    if (await tools.resolve(t) == null) {
      stdout.writeln('installing ${t.label}');
      await tools.install(t);
    }
  }
  final engine = ProcessEngine(tools);
  final st = await engine.status();
  for (final t in st.tools) {
    stdout.writeln('${t.name} ${t.found} ${t.version} ${t.path}');
  }
  final pl = await engine.fetchPlaylist(a[1]);
  stdout.writeln(
    'playlist "${pl.title}" ${pl.entries.length} entries; first ${pl.entries.first.id} ${pl.entries.first.duration}',
  );
  for (final page in a.skip(2)) {
    final pr = await engine.probe(page);
    stdout.writeln(
      'probe $page -> "${pr.title}" playlist=${pr.isPlaylist} '
      '${pr.entries.length} items; first ${pr.entries.firstOrNull?.id} heights ${pr.entries.firstOrNull?.heights}',
    );
  }
  final short = pl.entries.where((e) => e.duration != null).reduce((x, y) => x.duration! < y.duration! ? x : y);
  for (final mode in [MediaMode.audio, MediaMode.video]) {
    final task = engine.download(
      DownloadSpec(
        url: 'https://www.youtube.com/watch?v=${short.id}',
        fileKey: short.id,
        prefs: DownloadPrefs(mode: mode, maxHeight: 360),
        outputDir: '${a[0]}/out',
        thumbsDir: '${a[0]}/out/.thumbs',
      ),
    );
    var n = 0;
    task.progress.listen((p) {
      if (n++ % 20 == 0) stdout.writeln('  ${p.fraction} ${p.speedBps} ${p.eta}');
    });
    final f = await task.result;
    stdout.writeln('$mode -> ${f.filePath} (${await File(f.filePath).length()} bytes) thumb=${f.thumbPath}');
  }
}
