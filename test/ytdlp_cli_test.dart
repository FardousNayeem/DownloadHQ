import 'package:flutter_test/flutter_test.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/engine/engine.dart';
import 'package:downloadhq/engine/ytdlp_cli.dart';
import 'package:downloadhq/services/download_queue.dart';

void main() {
  const spec = DownloadSpec(
    url: 'https://www.youtube.com/watch?v=vid123',
    fileKey: 'vid123',
    prefs: DownloadPrefs(),
    outputDir: '/out',
    thumbsDir: '/th',
  );

  test('audio args extract m4a and end with the url', () {
    final a = downloadArgs(spec, const EnvFlags());
    expect(a, containsAllInOrder(['-x', '--audio-format', 'm4a']));
    expect(a.last, 'https://www.youtube.com/watch?v=vid123');
    expect(a, isNot(contains('--js-runtimes')));
  });

  test('video args cap height', () {
    final v = downloadArgs(
      const DownloadSpec(
        url: 'u',
        fileKey: 'v',
        prefs: DownloadPrefs(mode: MediaMode.video, maxHeight: 480),
        outputDir: '/o',
        thumbsDir: '/t',
      ),
      const EnvFlags(),
    );
    expect(v.join(' '), contains('height<=480'));
    expect(v, isNot(contains('-x')));
  });

  test('env flags pass tool locations', () {
    final a = downloadArgs(spec, const EnvFlags(ffmpegPath: '/f', jsRuntime: 'deno:/d', remoteEjs: true));
    expect(a, containsAllInOrder(['--ffmpeg-location', '/f', '--js-runtimes', 'deno:/d']));
    expect(a, containsAllInOrder(['--remote-components', 'ejs:github']));
  });

  test('sponsorblock, chapters and subtitles', () {
    DownloadSpec spec2(MediaMode mode, SponsorBlock sb, bool subs) => DownloadSpec(
      url: 'u',
      fileKey: 'k',
      prefs: DownloadPrefs(mode: mode),
      outputDir: '/o',
      thumbsDir: '/t',
      sponsorBlock: sb,
      subtitles: subs,
    );
    final off = downloadArgs(spec2(MediaMode.video, SponsorBlock.off, false), const EnvFlags());
    expect(off, contains('--embed-chapters'));
    expect(off.join(' '), isNot(contains('sponsorblock')));
    expect(off, isNot(contains('--embed-subs')));
    expect(
      downloadArgs(spec2(MediaMode.video, SponsorBlock.remove, true), const EnvFlags()),
      containsAllInOrder(['--sponsorblock-remove', 'sponsor,selfpromo,interaction', '--embed-subs']),
    );
    // Subtitles only go into video files.
    expect(
      downloadArgs(spec2(MediaMode.audio, SponsorBlock.off, true), const EnvFlags()),
      isNot(contains('--embed-subs')),
    );
    expect(
      downloadArgs(spec2(MediaMode.audio, SponsorBlock.mark, false), const EnvFlags()),
      containsAllInOrder(['--sponsorblock-mark', 'all']),
    );
  });

  test('page probes treat watch-in-playlist as the video', () {
    final a = probeArgs('https://www.youtube.com/watch?v=x&list=PLy', const EnvFlags());
    expect(a, containsAll(['--no-playlist', '--flat-playlist', '--dump-single-json']));
    expect(playlistArgs('u', const EnvFlags()), isNot(contains('--no-playlist')));
  });

  test('progress line parsing', () {
    final p = parseProgressLine('TSP 500 1000 NA 2048.5 12')!;
    expect(p.fraction, 0.5);
    expect(p.speedBps, 2048.5);
    expect(p.eta, const Duration(seconds: 12));
    // Unknown total falls back to the estimate.
    expect(parseProgressLine('TSP 250 NA 1000 NA NA')!.fraction, 0.25);
    expect(parseProgressLine('TSP 1 NA NA NA NA')!.fraction, isNull);
    expect(parseProgressLine('[download] 10%'), isNull);
  });

  test('final path is the last marker line', () {
    expect(parseFinalPath('junk\nTSF/a/b [x].m4a\n'), '/a/b [x].m4a');
    expect(parseFinalPath('nothing'), isNull);
  });

  test('playlist json parsing', () {
    const raw = '''
{"id":"PL1","title":"Road","channel":"Me","entries":[
 {"id":"a","title":"Song A","duration":61.0,"channel":"X","thumbnails":[{"url":"s"},{"url":"big"}]},
 {"id":"b","title":"[Private video]","duration":null},
 {"title":"no id"}
]}''';
    final p = parsePlaylistJson(raw);
    expect(p.title, 'Road');
    expect(p.entries, hasLength(2));
    expect(p.entries[0].duration, const Duration(seconds: 61));
    expect(p.entries[0].thumbnailUrl, 'big');
    expect(p.entries[1].unavailable, isTrue);
    expect(() => parsePlaylistJson('not json'), throwsA(isA<EngineException>()));
  });

  test('error summary picks the last ERROR line', () {
    expect(summariseError('WARNING: x\nERROR: [youtube] a: Video unavailable\n'), '[youtube] a: Video unavailable');
    expect(summariseError(''), 'yt-dlp failed');
  });

  test('folder names are filesystem safe', () {
    expect(folderName('AC/DC: Live?'), 'AC_DC_ Live_');
    expect(folderName('trailing dots...'), 'trailing dots');
    expect(folderName('  '), 'Playlist');
  });
}
