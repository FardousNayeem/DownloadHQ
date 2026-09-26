import 'package:flutter_test/flutter_test.dart';
import 'package:downloadhq/data/repositories.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/engine/engine.dart';
import 'package:downloadhq/services/library_service.dart';

class _MemRepo implements LibraryRepository {
  List<Playlist> saved = [];
  @override
  Future<List<Playlist>> load() async => saved;
  @override
  Future<void> save(List<Playlist> p) async => saved = p;
}

class _NoEngine implements YtDlpEngine {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  const a = RemoteEntry(id: 'Soundcloud:1', title: 'A', url: 'https://sc/a');
  const b = RemoteEntry(id: 'b', title: 'B', url: 'https://yt/b');

  test('addFromWeb creates the web collection, dedupes, keeps downloaded files', () async {
    final lib = LibraryService(_MemRepo(), _NoEngine());
    await lib.load();
    lib.addFromWeb([a], const DownloadPrefs(mode: MediaMode.audio));
    lib.markDownloaded(Playlist.webId, a.id, const DownloadedFile(filePath: '/a.m4a'));
    lib.addFromWeb([a, b], const DownloadPrefs(mode: MediaMode.video, maxHeight: 480));

    final web = lib.byId(Playlist.webId)!;
    expect(web.isWeb, isTrue);
    expect(web.entries, hasLength(2));
    expect(web.entry(a.id)!.filePath, '/a.m4a'); // not reset by re-grab
    expect(web.entry(b.id)!.prefs!.maxHeight, 480);
    expect(web.entry(b.id)!.downloadUrl, 'https://yt/b');
  });

  test('sync ignores the web collection', () async {
    final lib = LibraryService(_MemRepo(), _NoEngine());
    await lib.load();
    lib.addFromWeb([a], const DownloadPrefs());
    await lib.syncAll(); // would throw via _NoEngine if it tried
    expect(lib.byId(Playlist.webId)!.lastSyncError, isNull);
  });
}
