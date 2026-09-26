import 'package:flutter_test/flutter_test.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/domain/sync_diff.dart';

RemoteEntry r(String id, {bool gone = false}) =>
    RemoteEntry(id: id, title: gone ? '[Private video]' : 'Title $id', unavailable: gone);

RemotePlaylist remote(List<RemoteEntry> e) => RemotePlaylist(id: 'PL1', title: 'Mix', entries: e);

void main() {
  final t0 = DateTime(2026, 1, 1);
  final t1 = DateTime(2026, 1, 2);
  const blank = Playlist(id: 'PL1', url: 'u', title: '', entries: []);

  test('first sync imports everything without flagging new', () {
    final res = mergeRemote(blank, remote([r('a'), r('b')]), t0);
    expect(res.added, isEmpty);
    expect(res.playlist.entries.map((e) => e.id), ['a', 'b']);
    expect(res.playlist.entries.any((e) => e.isNew), isFalse);
    expect(res.playlist.lastSynced, t0);
  });

  test('later sync flags only unseen ids as new', () {
    final first = mergeRemote(blank, remote([r('a')]), t0).playlist;
    final res = mergeRemote(first, remote([r('b'), r('a')]), t1);
    expect(res.added, ['b']);
    expect(res.playlist.entry('b')!.isNew, isTrue);
    expect(res.playlist.entry('a')!.isNew, isFalse);
    expect(res.playlist.entry('b')!.position, 0);
  });

  test('removed entries are kept, flagged, and keep their file', () {
    var p = mergeRemote(blank, remote([r('a'), r('b')]), t0).playlist;
    p = p.copyWith(entries: [for (final e in p.entries) e.id == 'a' ? e.copyWith(filePath: '/x.m4a') : e]);
    final res = mergeRemote(p, remote([r('b')]), t1);
    expect(res.removed, ['a']);
    final a = res.playlist.entry('a')!;
    expect(a.removedFromSource, isTrue);
    expect(a.filePath, '/x.m4a');
    // Reported once, not on every later sync.
    expect(mergeRemote(res.playlist, remote([r('b')]), t1).removed, isEmpty);
  });

  test('video going private keeps its known title', () {
    final first = mergeRemote(blank, remote([r('a')]), t0).playlist;
    final res = mergeRemote(first, remote([r('a', gone: true)]), t1);
    expect(res.playlist.entry('a')!.title, 'Title a');
    expect(res.playlist.entry('a')!.unavailable, isTrue);
  });

  test('new private placeholder is not flagged new', () {
    final first = mergeRemote(blank, remote([r('a')]), t0).playlist;
    final res = mergeRemote(first, remote([r('a'), r('z', gone: true)]), t1);
    expect(res.playlist.entry('z')!.isNew, isFalse);
  });

  test('duplicates in remote collapse to one entry', () {
    final res = mergeRemote(blank, remote([r('a'), r('a')]), t0);
    expect(res.playlist.entries, hasLength(1));
  });

  test('ignored flag survives sync', () {
    var p = mergeRemote(blank, remote([r('a')]), t0).playlist;
    p = p.copyWith(entries: [p.entries.first.copyWith(ignored: true)]);
    expect(mergeRemote(p, remote([r('a')]), t1).playlist.entry('a')!.ignored, isTrue);
  });

  group('parsePlaylistId', () {
    test('from watch url with list param', () {
      expect(parsePlaylistId('https://www.youtube.com/watch?v=abc&list=PLxyz1234567890'), 'PLxyz1234567890');
    });
    test('from playlist url', () {
      expect(parsePlaylistId(' https://youtube.com/playlist?list=PL_a-b123456789 '), 'PL_a-b123456789');
    });
    test('bare id', () => expect(parsePlaylistId('PLabcdefghijkl'), 'PLabcdefghijkl'));
    test('rejects junk', () => expect(parsePlaylistId('hello'), isNull));
  });

  test('json round trip', () {
    final p = mergeRemote(
      blank,
      remote([r('a')]),
      t0,
    ).playlist.copyWith(prefs: const DownloadPrefs(mode: MediaMode.video, maxHeight: 1080, autoDownloadNew: true));
    final back = Playlist.fromJson(p.toJson());
    expect(back.prefs.mode, MediaMode.video);
    expect(back.prefs.maxHeight, 1080);
    expect(back.entry('a')!.firstSeen, t0);
    expect(back.lastSynced, t0);
  });
}
