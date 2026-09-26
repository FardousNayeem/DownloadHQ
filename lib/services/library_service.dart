import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/repositories.dart';
import '../domain/models.dart';
import '../domain/sync_diff.dart';
import '../engine/engine.dart';

class NewEntries {
  const NewEntries(this.playlist, this.entryIds);
  final Playlist playlist;
  final List<String> entryIds;
}

/// Owns the playlist library: adding, syncing, and every change to local
/// entry state. The only writer of [LibraryRepository].
class LibraryService extends ChangeNotifier {
  LibraryService(this._repo, this._engine);

  final LibraryRepository _repo;
  final YtDlpEngine _engine;

  List<Playlist> _playlists = [];
  final Set<String> _syncing = {};
  final _newEntries = StreamController<NewEntries>.broadcast();
  bool _loaded = false;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  bool get loaded => _loaded;
  bool isSyncing(String playlistId) => _syncing.contains(playlistId);
  bool get anySyncing => _syncing.isNotEmpty;
  int get totalNew => _playlists.fold(0, (n, p) => n + p.newCount);

  /// Fires after a sync finds entries that were not there before.
  Stream<NewEntries> get newEntries => _newEntries.stream;

  Playlist? byId(String id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> load() async {
    _playlists = await _repo.load();
    _loaded = true;
    notifyListeners();
  }

  void _put(Playlist p) {
    final i = _playlists.indexWhere((x) => x.id == p.id);
    if (i < 0) {
      _playlists = [..._playlists, p];
    } else {
      _playlists = [..._playlists]..[i] = p;
    }
    notifyListeners();
    _repo.save(_playlists);
  }

  void _updateEntry(String playlistId, String entryId, Entry Function(Entry) f) {
    final p = byId(playlistId);
    if (p == null) return;
    _put(p.copyWith(entries: [for (final e in p.entries) e.id == entryId ? f(e) : e]));
  }

  /// Adds a playlist by URL and runs its first sync. Throws [EngineException]
  /// with a readable message on bad input or network failure.
  Future<Playlist> add(String input) async {
    final id = parsePlaylistId(input);
    if (id == null) throw EngineException('That does not look like a YouTube playlist link.');
    final existing = byId(id);
    if (existing != null) return existing;
    final url = canonicalPlaylistUrl(id);
    _syncing.add(id);
    notifyListeners();
    try {
      final remote = await _engine.fetchPlaylist(url);
      final blank = Playlist(id: id, url: url, title: remote.title, entries: const []);
      final result = mergeRemote(blank, remote, DateTime.now());
      _put(result.playlist);
      return result.playlist;
    } finally {
      _syncing.remove(id);
      notifyListeners();
    }
  }

  Future<void> sync(String playlistId) async {
    final p = byId(playlistId);
    if (p == null || p.isWeb || _syncing.contains(playlistId)) return;
    _syncing.add(playlistId);
    notifyListeners();
    try {
      final remote = await _engine.fetchPlaylist(p.url);
      // Re-read: entries may have changed (downloads finished) during the fetch.
      final current = byId(playlistId);
      if (current == null) return;
      final result = mergeRemote(current, remote, DateTime.now());
      _put(result.playlist);
      if (result.added.isNotEmpty) _newEntries.add(NewEntries(result.playlist, result.added));
    } catch (e) {
      final current = byId(playlistId);
      if (current != null) _put(current.copyWith(lastSyncError: e.toString()));
    } finally {
      _syncing.remove(playlistId);
      notifyListeners();
    }
  }

  /// Sequential on purpose: parallel yt-dlp listings get rate limited.
  Future<void> syncAll() async {
    for (final p in [..._playlists]) {
      if (!p.isWeb) await sync(p.id);
    }
  }

  /// Files items found while browsing under the "From the web" collection,
  /// each with its own download prefs. Returns their ids for queueing.
  List<String> addFromWeb(List<RemoteEntry> items, DownloadPrefs prefs) {
    final web = byId(Playlist.webId) ?? const Playlist(id: Playlist.webId, url: '', title: 'From the web', entries: []);
    final now = DateTime.now();
    final entries = [...web.entries];
    for (final r in items) {
      final i = entries.indexWhere((e) => e.id == r.id);
      final entry = Entry(
        id: r.id,
        title: r.title,
        channel: r.channel,
        duration: r.duration,
        thumbnailUrl: r.thumbnailUrl,
        position: 0,
        firstSeen: now,
        sourceUrl: r.url,
        prefs: prefs,
      );
      if (i < 0) {
        entries.add(entry);
      } else if (!entries[i].isDownloaded) {
        entries[i] = entry; // re-grab with new prefs
      }
    }
    // Newest grabs first.
    entries.sort((a, b) => b.firstSeen.compareTo(a.firstSeen));
    _put(web.copyWith(entries: [for (var i = 0; i < entries.length; i++) entries[i].copyWith(position: i)]));
    return [for (final r in items) r.id];
  }

  Future<void> remove(String playlistId, {required bool deleteFiles}) async {
    final p = byId(playlistId);
    if (p == null) return;
    if (deleteFiles) {
      for (final e in p.entries) {
        await _deleteQuietly(e.filePath);
        await _deleteQuietly(e.thumbPath);
      }
    }
    _playlists = [..._playlists]..removeWhere((x) => x.id == playlistId);
    notifyListeners();
    await _repo.save(_playlists);
  }

  void setPrefs(String playlistId, DownloadPrefs prefs) {
    final p = byId(playlistId);
    if (p != null) _put(p.copyWith(prefs: prefs));
  }

  /// Clears the "new" flag on everything in the playlist.
  void acknowledgeNew(String playlistId) {
    final p = byId(playlistId);
    if (p == null || p.newCount == 0) return;
    _put(p.copyWith(entries: [for (final e in p.entries) e.isNew ? e.copyWith(isNew: false) : e]));
  }

  void setIgnored(String playlistId, Set<String> entryIds, bool ignored) {
    final p = byId(playlistId);
    if (p == null) return;
    _put(
      p.copyWith(
        entries: [for (final e in p.entries) entryIds.contains(e.id) ? e.copyWith(ignored: ignored, isNew: false) : e],
      ),
    );
  }

  void markDownloaded(String playlistId, String entryId, DownloadedFile f) => _updateEntry(
    playlistId,
    entryId,
    (e) => e.copyWith(filePath: f.filePath, thumbPath: f.thumbPath, isNew: false, lastError: null),
  );

  void markFailed(String playlistId, String entryId, String error) =>
      _updateEntry(playlistId, entryId, (e) => e.copyWith(lastError: error));

  Future<void> deleteDownload(String playlistId, String entryId) async {
    final e = byId(playlistId)?.entry(entryId);
    if (e == null) return;
    await _deleteQuietly(e.filePath);
    _updateEntry(playlistId, entryId, (e) => e.copyWith(filePath: null));
  }

  /// Files deleted outside the app come back as "not downloaded".
  Future<void> verifyFiles() async {
    for (final p in [..._playlists]) {
      final missing = <String>{};
      for (final e in p.entries) {
        if (e.filePath != null && !await File(e.filePath!).exists()) missing.add(e.id);
      }
      if (missing.isEmpty) continue;
      _put(p.copyWith(entries: [for (final e in p.entries) missing.contains(e.id) ? e.copyWith(filePath: null) : e]));
    }
  }

  Future<void> _deleteQuietly(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _newEntries.close();
    super.dispose();
  }
}
