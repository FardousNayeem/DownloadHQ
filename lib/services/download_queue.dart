import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import 'library_service.dart';
import 'settings_service.dart';

enum JobState { queued, running, failed }

class DownloadJob {
  DownloadJob(this.playlistId, this.entryId, this.title);

  final String playlistId;
  final String entryId;
  final String title;
  JobState state = JobState.queued;
  DownloadProgress? progress;
  String? error;
  DownloadTask? _task;
}

/// Runs downloads with a concurrency cap. Finished jobs leave the queue; their
/// result lives on the entry in [LibraryService]. Failed jobs stay until
/// retried or dismissed.
class DownloadQueue extends ChangeNotifier {
  DownloadQueue(this._engine, this._library, this._settings) {
    _sub = _library.newEntries.listen(_onNewEntries);
    // Raising "downloads at once" should start more right away.
    _settings.addListener(_pump);
  }

  final YtDlpEngine _engine;
  final LibraryService _library;
  final SettingsService _settings;
  late final StreamSubscription _sub;

  final List<DownloadJob> _jobs = [];
  Timer? _notifyThrottle;

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);
  int get activeCount => _jobs.where((j) => j.state != JobState.failed).length;

  DownloadJob? jobFor(String playlistId, String entryId) {
    for (final j in _jobs) {
      if (j.playlistId == playlistId && j.entryId == entryId) return j;
    }
    return null;
  }

  void _onNewEntries(NewEntries n) {
    if (n.playlist.prefs.autoDownloadNew) enqueue(n.playlist.id, n.entryIds);
  }

  /// Returns how many entries are now waiting or running because of this
  /// call (already saved and already queued ones don't count).
  int enqueue(String playlistId, Iterable<String> entryIds) {
    final pl = _library.byId(playlistId);
    if (pl == null) return 0;
    var added = 0;
    for (final id in entryIds) {
      final e = pl.entry(id);
      if (e == null || e.isDownloaded || e.unavailable) continue;
      final existing = jobFor(playlistId, id);
      if (existing != null) {
        if (existing.state == JobState.failed) {
          existing
            ..state = JobState.queued
            ..error = null
            ..progress = null;
          added++;
        }
        continue;
      }
      _jobs.add(DownloadJob(playlistId, id, e.title));
      added++;
    }
    notifyListeners();
    _pump();
    return added;
  }

  void retry(DownloadJob j) {
    if (j.state != JobState.failed) return;
    j
      ..state = JobState.queued
      ..error = null
      ..progress = null;
    notifyListeners();
    _pump();
  }

  void retryAllFailed() {
    for (final j in _jobs.where((j) => j.state == JobState.failed)) {
      j
        ..state = JobState.queued
        ..error = null
        ..progress = null;
    }
    notifyListeners();
    _pump();
  }

  void cancel(DownloadJob j) {
    _jobs.remove(j);
    j._task?.cancel();
    notifyListeners();
    _pump();
  }

  void cancelPlaylist(String playlistId) {
    for (final j in _jobs.where((j) => j.playlistId == playlistId).toList()) {
      cancel(j);
    }
  }

  void _pump() {
    final limit = _settings.value.parallelDownloads.clamp(1, 4);
    var running = _jobs.where((j) => j.state == JobState.running).length;
    for (final j in [..._jobs]) {
      if (running >= limit) break;
      if (j.state != JobState.queued) continue;
      running++;
      _run(j);
    }
  }

  Future<void> _run(DownloadJob j) async {
    final pl = _library.byId(j.playlistId);
    final entry = pl?.entry(j.entryId);
    if (pl == null || entry == null) {
      // The playlist went away while this waited. _pump counted it as
      // started, so hand its slot on.
      _jobs.remove(j);
      notifyListeners();
      scheduleMicrotask(_pump);
      return;
    }
    j.state = JobState.running;
    final settings = _settings.value;
    final root = settings.downloadDir;
    final task = _engine.download(
      DownloadSpec(
        url: entry.downloadUrl,
        fileKey: entry.fileKey,
        prefs: entry.prefs ?? pl.prefs,
        outputDir: p.join(root, folderName(pl.title)),
        thumbsDir: p.join(root, '.thumbs'),
        sponsorBlock: settings.sponsorBlock,
        subtitles: settings.embedSubtitles,
      ),
    );
    j._task = task;
    notifyListeners();
    final sub = task.progress.listen((pr) {
      j.progress = pr;
      _notifySoon();
    });
    try {
      final file = await task.result;
      _library.markDownloaded(j.playlistId, j.entryId, file);
      _jobs.remove(j);
    } on DownloadCancelled {
      // Already removed by cancel().
    } catch (e) {
      if (_jobs.contains(j)) {
        j
          ..state = JobState.failed
          ..error = e.toString();
        _library.markFailed(j.playlistId, j.entryId, e.toString());
      }
    } finally {
      await sub.cancel();
      j._task = null;
      notifyListeners();
      _pump();
    }
  }

  /// Progress ticks arrive many times a second; repaint at most 4x/s.
  void _notifySoon() {
    if (_notifyThrottle?.isActive ?? false) return;
    _notifyThrottle = Timer(const Duration(milliseconds: 250), notifyListeners);
  }

  @override
  void dispose() {
    _sub.cancel();
    _settings.removeListener(_pump);
    _notifyThrottle?.cancel();
    for (final j in _jobs) {
      j._task?.cancel();
    }
    super.dispose();
  }
}

/// Folder-safe version of a playlist title (Windows is the strictest).
@visibleForTesting
String folderName(String title) {
  final s = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  final t = s.replaceAll(RegExp(r'[. ]+$'), '');
  return t.isEmpty ? 'Playlist' : (t.length > 80 ? t.substring(0, 80).trim() : t);
}
