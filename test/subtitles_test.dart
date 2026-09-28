import 'package:downloadhq/data/repositories.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/domain/subtitles.dart';
import 'package:downloadhq/engine/engine.dart';
import 'package:downloadhq/engine/ffmpeg.dart';
import 'package:downloadhq/engine/ytdlp_cli.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DownloadSpec spec({bool subs = true, bool auto = true}) => DownloadSpec(
    url: 'u',
    fileKey: 'k',
    prefs: const DownloadPrefs(mode: MediaMode.video),
    outputDir: '/o',
    thumbsDir: '/t',
    subtitles: subs,
    autoCaptions: auto,
  );

  test('subtitles are embedded and the separate file is not kept', () {
    final a = downloadArgs(spec(), const EnvFlags());
    expect(a, containsAllInOrder(['--write-subs', '--write-auto-subs', '--sub-langs', 'en.*,-en-orig,-live_chat']));
    expect(a, containsAllInOrder(['--convert-subs', 'srt', '--embed-subs']));
    expect(a, containsAllInOrder(['--compat-options', 'no-keep-subs']));
    expect(a, containsAllInOrder(['--ppa', 'EmbedSubtitle+ffmpeg_o:-disposition:s:0 default']));
    expect(downloadArgs(spec(auto: false), const EnvFlags()), isNot(contains('--write-auto-subs')));
    expect(downloadArgs(spec(subs: false), const EnvFlags()), isNot(contains('--embed-subs')));
  });

  test('caption fetch failures are told apart', () {
    expect(isSubtitleError("Unable to download video subtitles for 'en': HTTP Error 429"), isTrue);
    expect(isSubtitleError('Read timed out'), isFalse);
  });

  test('finds the subtitle files that belong to a video, English first', () {
    const v = '/d/Song [abc].mp4';
    final subs = sidecarsFor(v, [
      '/d/Song [abc].mp4',
      '/d/Song [abc].fr.vtt',
      '/d/Song [abc].en-US.srt',
      '/d/Song [abc].part2.srt',
      '/d/Other [x].en.srt',
      '/d/Song [abc].jpg',
    ]);
    expect(subs.map((s) => s.lang), ['en-US', 'fr']);
  });

  test('merge copies streams, adds tracks with language and the first as default', () {
    final a = mergeSubsArgs('/d/v.mp4', const [
      SidecarSub('/d/v.en.srt', 'en'),
      SidecarSub('/d/v.fr.vtt', 'fr'),
    ], '/d/o.mp4');
    expect(a, containsAllInOrder(['-i', '/d/v.mp4', '-i', '/d/v.en.srt', '-i', '/d/v.fr.vtt']));
    expect(a, containsAllInOrder(['-map', '1:0', '-map', '2:0']));
    expect(a, containsAllInOrder(['-c', 'copy', '-c:s', 'mov_text']));
    expect(a, containsAllInOrder(['-metadata:s:s:0', 'language=eng', '-metadata:s:s:0', 'title=English']));
    expect(a, containsAllInOrder(['-disposition:s:0', 'default', '-disposition:s:1', '0']));
    expect(a.last, '/d/o.mp4');
    expect(subtitleCodecFor('/x.mkv'), 'srt');
    expect(subtitleCodecFor('/x.webm'), 'webvtt');
  });

  test('burn-in reads progress and keeps the filter free of paths', () {
    final a = burnSubsArgs('/d/My video [x].mp4', '/tmp/out.mp4');
    expect(a[a.indexOf('-vf') + 1], startsWith('subtitles=sub.srt'));
    expect(parseFfmpegProgress('out_time_ms=1500000'), const Duration(milliseconds: 1500));
    expect(parseFfmpegProgress('frame=10'), isNull);
    expect(lastFfmpegError('banner\nstream list\n\nInvalid data found\n'), 'Invalid data found');
  });

  test('language codes for players', () {
    expect(iso639_2('en-US'), 'eng');
    expect(iso639_2('bn'), 'ben');
    expect(iso639_2('xx'), 'und');
    expect(subtitleTitle('en-orig'), 'English (automatic)');
  });

  test('settings: the old subtitle switch carries over', () {
    expect(AppSettings.fromJson(const {'embedSubtitles': true}, '/d').subtitleMode, SubtitleMode.embed);
    expect(AppSettings.fromJson(const {'embedSubtitles': false}, '/d').subtitleMode, SubtitleMode.off);
    expect(AppSettings.fromJson(const {}, '/d').subtitleMode, SubtitleMode.embed);
    final v = const AppSettings(downloadDir: '/d', subtitleMode: SubtitleMode.burn, autoCaptions: false);
    final back = AppSettings.fromJson(v.toJson(), '/d');
    expect(back.subtitleMode, SubtitleMode.burn);
    expect(back.autoCaptions, isFalse);
  });
}
