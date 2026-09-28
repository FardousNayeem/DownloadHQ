import 'dart:io';

import 'package:downloadhq/data/json_store.dart';
import 'package:downloadhq/data/repositories.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/domain/sync_diff.dart';
import 'package:downloadhq/engine/engine.dart';
import 'package:downloadhq/engine/ytdlp_cli.dart';
import 'package:downloadhq/services/cookie_service.dart';
import 'package:downloadhq/services/download_queue.dart';
import 'package:downloadhq/services/library_service.dart';
import 'package:downloadhq/services/playback_service.dart';
import 'package:downloadhq/services/settings_service.dart';
import 'package:downloadhq/services/tools_service.dart';
import 'package:downloadhq/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webview_all/webview_all.dart' show WebViewCookie;

class _MemRepo implements LibraryRepository {
  List<Playlist> saved = [];
  @override
  Future<List<Playlist>> load() async => saved;
  @override
  Future<void> save(List<Playlist> p) async => saved = p;
}

class _Task implements DownloadTask {
  _Task(this._result);
  final Future<DownloadedFile> _result;
  @override
  Stream<DownloadProgress> get progress => const Stream.empty();
  @override
  Future<DownloadedFile> get result => _result;
  @override
  void cancel() {}
}

/// Fails with the queued errors in order, then succeeds.
class _ScriptedEngine implements YtDlpEngine {
  _ScriptedEngine(this.errors);
  final List<String> errors;
  final specs = <DownloadSpec>[];

  @override
  DownloadTask download(DownloadSpec spec) {
    specs.add(spec);
    if (errors.isNotEmpty) return _Task(Future.error(EngineException(errors.removeAt(0))));
    return _Task(Future.value(const DownloadedFile(filePath: '/x.mp4')));
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakeCookies extends CookieService {
  _FakeCookies(this.file) : super('/nowhere');
  final String? file;
  final released = <String?>[];
  @override
  Future<String?> exportFor(String url) async => file;
  @override
  Future<void> release(String? path) async => released.add(path);
}

class _NullStore implements JsonStore {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value();
}

Future<(DownloadQueue, LibraryService)> _queue(_ScriptedEngine engine, {CookieService? cookies}) async {
  final lib = LibraryService(_MemRepo(), engine);
  await lib.load();
  lib.addFromWeb([
    const RemoteEntry(id: 'v1', title: 'Video', url: 'https://www.youtube.com/watch?v=v1'),
  ], const DownloadPrefs(mode: MediaMode.video));
  final settings = SettingsService(SettingsRepository(_NullStore(), '/dl'), const AppSettings(downloadDir: '/dl'));
  final q = DownloadQueue(engine, lib, settings, cookies: cookies, retryDelay: (_) => Duration.zero);
  return (q, lib);
}

Future<void> _settle(DownloadQueue q) async {
  for (var i = 0; i < 50 && q.jobs.any((j) => j.state != JobState.failed); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('error classes', () {
    test('sign-in walls are auth errors', () {
      expect(isAuthError('[youtube] x: Private video. Sign in if you\'ve been granted access'), isTrue);
      expect(isAuthError('Sign in to confirm you\'re not a bot'), isTrue);
      expect(isAuthError('Join this channel to get access to members-only content'), isTrue);
      expect(isAuthError('Unable to download webpage: timed out'), isFalse);
    });

    test('network trouble is transient, and unreachable asks for IPv4', () {
      const msg = 'Unable to download webpage: <urlopen error [Errno 101] Network is unreachable>';
      expect(isTransientError(msg), isTrue);
      expect(isRoutingError(msg), isTrue);
      expect(isTransientError('Video unavailable. This video has been removed by the uploader'), isFalse);
    });
  });

  test('download args retry the network and carry cookies and IPv4 when asked', () {
    const spec = DownloadSpec(url: 'u', fileKey: 'k', prefs: DownloadPrefs(), outputDir: '/o', thumbsDir: '/t');
    final plain = downloadArgs(spec, const EnvFlags());
    expect(plain, containsAll(['--retries', '--fragment-retries', '--socket-timeout']));
    expect(plain, isNot(contains('--cookies')));
    expect(plain, isNot(contains('--force-ipv4')));
    final more = downloadArgs(spec.copyWith(cookiesFile: '/c.txt', forceIpv4: true), const EnvFlags());
    expect(more.sublist(more.indexOf('--cookies'), more.indexOf('--cookies') + 2), ['--cookies', '/c.txt']);
    expect(more, contains('--force-ipv4'));
    expect(probeArgs('u', const EnvFlags(), cookiesFile: '/c'), contains('/c'));
  });

  group('download queue', () {
    test('retries a dropped connection, then over IPv4, then succeeds', () async {
      final engine = _ScriptedEngine(['[Errno 101] Network is unreachable', 'Read timed out']);
      final (q, lib) = await _queue(engine);
      q.enqueue(Playlist.webId, ['v1']);
      await _settle(q);
      expect(q.jobs, isEmpty);
      expect(lib.byId(Playlist.webId)!.entry('v1')!.filePath, '/x.mp4');
      expect(engine.specs.map((s) => s.forceIpv4), [false, true, true]);
    });

    test('gives up after the last attempt with the error shown', () async {
      final engine = _ScriptedEngine(List.filled(DownloadQueue.maxAttempts, 'Read timed out', growable: true));
      final (q, _) = await _queue(engine);
      q.enqueue(Playlist.webId, ['v1']);
      await _settle(q);
      expect(q.jobs.single.state, JobState.failed);
      expect(q.jobs.single.error, 'Read timed out');
      expect(engine.specs, hasLength(DownloadQueue.maxAttempts));
    });

    test('a private video is retried once with browser cookies, which are then deleted', () async {
      final engine = _ScriptedEngine(['Private video. Sign in if you have access']);
      final cookies = _FakeCookies('/tmp/c.txt');
      final (q, lib) = await _queue(engine, cookies: cookies);
      q.enqueue(Playlist.webId, ['v1']);
      await _settle(q);
      expect(q.jobs, isEmpty);
      expect(engine.specs.map((s) => s.cookiesFile), [null, '/tmp/c.txt']);
      expect(cookies.released, ['/tmp/c.txt']);
      expect(lib.byId(Playlist.webId)!.entry('v1')!.isDownloaded, isTrue);
    });

    test('without a browser sign-in the failure says how to fix it', () async {
      final engine = _ScriptedEngine(['Private video. Sign in if you have access']);
      final (q, _) = await _queue(engine, cookies: _FakeCookies(null));
      q.enqueue(Playlist.webId, ['v1']);
      await _settle(q);
      expect(q.jobs.single.error, contains('Browse tab'));
      expect(engine.specs, hasLength(1));
    });
  });

  test('cookie lines are in Netscape format for the whole site', () {
    final line = netscapeLine(
      const WebViewCookie(name: 'SID', value: 'a\tb', domain: 'www.youtube.com'),
      'youtube.com',
    );
    final f = line.split('\t');
    expect(f, hasLength(7));
    expect(f.sublist(0, 4), ['.youtube.com', 'TRUE', '/', 'TRUE']);
    expect(f.sublist(5), ['SID', 'ab']);
  });

  group('rename', () {
    test('file names keep the id and drop unsafe characters', () {
      expect(renamedStem('A/B: c?', 'Vimeo:12'), 'A_B_ c_ [Vimeo_12]');
      expect(renamedStem('  ...  ', 'x'), '[x]');
    });

    test('renames the file and a later sync keeps the title', () async {
      final dir = await Directory.systemTemp.createTemp('dhq');
      addTearDown(() => dir.delete(recursive: true));
      final old = File(p.join(dir.path, 'Old [v1].mp4'))..writeAsStringSync('x');
      final lib = LibraryService(_MemRepo(), _ScriptedEngine([]));
      await lib.load();
      lib.addFromWeb([const RemoteEntry(id: 'v1', title: 'Old', url: 'u')], const DownloadPrefs());
      lib.markDownloaded(Playlist.webId, 'v1', DownloadedFile(filePath: old.path));

      final e = (await lib.rename(Playlist.webId, 'v1', 'My name'))!;
      expect(e.title, 'My name');
      expect(p.basename(e.filePath!), 'My name [v1].mp4');
      expect(File(e.filePath!).existsSync(), isTrue);
      expect(old.existsSync(), isFalse);

      final local = Playlist(id: 'PL', url: 'u', title: 't', entries: [e], lastSynced: DateTime(2026));
      final merged = mergeRemote(
        local,
        const RemotePlaylist(
          id: 'PL',
          title: 't',
          entries: [RemoteEntry(id: 'v1', title: 'Remote title')],
        ),
        DateTime(2026, 2),
      );
      expect(merged.playlist.entries.single.title, 'My name');
      expect(Entry.fromJson(e.toJson()).renamed, isTrue);
    });
  });

  test('search matches every word, in any field, ignoring case', () {
    expect(matchesQuery('lofi beats', ['Chill LoFi', 'Beats channel']), isTrue);
    expect(matchesQuery('lofi jazz', ['Chill LoFi', null]), isFalse);
    expect(matchesQuery('  ', ['anything']), isTrue);
  });

  test('video files are told apart from audio by extension', () {
    expect(isVideoPath('/a/b [x].MP4'), isTrue);
    expect(isVideoPath('/a/b [x].m4a'), isFalse);
    expect(isVideoPath(null), isFalse);
  });

  test('backoff grows', () {
    expect(DownloadQueue.backoff(1) < DownloadQueue.backoff(3), isTrue);
  });

  test('yt-dlp auto update runs at most once a day', () {
    final now = DateTime(2026, 9, 28, 12);
    expect(updateDue(null, now), isTrue);
    expect(updateDue(now.subtract(const Duration(hours: 23)), now), isFalse);
    expect(updateDue(now.subtract(const Duration(hours: 25)), now), isTrue);
  });

  test('new settings survive a save and load', () {
    final v = AppSettings(
      downloadDir: '/d',
      cookiesFile: '/c.txt',
      autoUpdateYtDlp: false,
      lastYtDlpUpdate: DateTime(2026, 9, 1),
    );
    final back = AppSettings.fromJson(v.toJson(), '/x');
    expect(back.cookiesFile, '/c.txt');
    expect(back.autoUpdateYtDlp, isFalse);
    expect(back.lastYtDlpUpdate, DateTime(2026, 9, 1));
    expect(back.copyWith(cookiesFile: null).cookiesFile, isNull);
    expect(AppSettings.fromJson(const {}, '/x').autoUpdateYtDlp, isTrue);
  });

  test('a picked cookies file is used as a copy, never handed over itself', () async {
    final dir = await Directory.systemTemp.createTemp('dhq');
    addTearDown(() => dir.delete(recursive: true));
    final mine = File(p.join(dir.path, 'mine.txt'))..writeAsStringSync('.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tx\n');
    final c = CookieService(p.join(dir.path, 'session'), userFile: () => mine.path);
    final got = await c.exportFor('https://youtu.be/abc');
    expect(got, isNot(mine.path));
    expect(File(got!).readAsStringSync(), mine.readAsStringSync());
    await c.release(got);
    expect(File(got).existsSync(), isFalse);
    expect(mine.existsSync(), isTrue);
  });
}
