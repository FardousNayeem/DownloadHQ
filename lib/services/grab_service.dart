import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../engine/engine.dart';
import 'download_queue.dart';
import 'library_service.dart';

enum ProbeState { idle, looking, found, none }

/// Watches the page open in the browser and asks yt-dlp what it can take
/// from it. Owns no widget: the browser screen reports URL changes and
/// renders [state].
class GrabService extends ChangeNotifier {
  GrabService(this._engine, this._library, this._queue);

  final YtDlpEngine _engine;
  final LibraryService _library;
  final DownloadQueue _queue;

  /// Pages settle (redirects, SPA route changes) before we spend a yt-dlp run.
  static const debounce = Duration(milliseconds: 1200);

  String? _url;
  Timer? _timer;
  ProbeState state = ProbeState.idle;
  ProbeResult? result;
  String? reason;

  String? get url => _url;

  /// Called on every navigation. Probing starts once the URL stops changing.
  void pageChanged(String url) {
    if (url == _url) return;
    _url = url;
    _timer?.cancel();
    result = null;
    reason = null;
    if (!_worthProbing(url)) {
      state = ProbeState.idle;
      notifyListeners();
      return;
    }
    state = ProbeState.looking;
    notifyListeners();
    _timer = Timer(debounce, () => _probe(url));
  }

  /// Manual retry, e.g. after the user updated yt-dlp.
  void probeAgain() {
    final u = _url;
    if (u == null) return;
    _timer?.cancel();
    state = ProbeState.looking;
    notifyListeners();
    _probe(u);
  }

  Future<void> _probe(String url) async {
    try {
      final r = await _engine.probe(url);
      if (url != _url) return; // user moved on; drop stale answer
      result = r;
      state = r.entries.isEmpty ? ProbeState.none : ProbeState.found;
      reason = r.entries.isEmpty ? 'This page lists no media.' : null;
    } catch (e) {
      if (url != _url) return;
      state = ProbeState.none;
      reason = friendlyProbeError(e.toString());
    }
    notifyListeners();
  }

  /// Queues the chosen items. Returns how many were queued; items already
  /// saved or downloading are not queued again.
  int download(List<RemoteEntry> items, DownloadPrefs prefs) {
    final ids = _library.addFromWeb(items, prefs);
    return _queue.enqueue(Playlist.webId, ids);
  }

  /// The page is a YouTube playlist that could be tracked for new videos.
  String? get trackablePlaylistId => _url == null ? null : parsePlaylistId(_url!);

  Future<Playlist> track() => _library.add(_url!);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Search result pages and site home pages never hold a single downloadable
/// item; skipping them saves a yt-dlp run on every keystroke-driven search.
@visibleForTesting
bool worthProbing(String url) => _worthProbing(url);

bool _worthProbing(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return false;
  // Only a leading `www.` or `m.`: "tm.example" is not "m.example".
  final host = u.host.replaceFirst(RegExp(r'^(www|m)\.'), '');
  if (u.path.isEmpty || u.path == '/') return false;
  if (RegExp(r'^(duckduckgo|google|bing|search\.brave|startpage)\.').hasMatch(host)) return false;
  if (host.endsWith('youtube.com') &&
      (u.path.startsWith('/results') || u.path == '/search' || u.path.startsWith('/feed/'))) {
    return false;
  }
  return true;
}

/// yt-dlp errors are written for terminals; say it plainly.
@visibleForTesting
String friendlyProbeError(String raw) {
  if (raw.contains('Unsupported URL')) return 'Nothing downloadable on this page.';
  if (raw.contains('logged-in') || raw.contains('cookies') || raw.contains('Sign in')) {
    return 'This needs you signed in. Sign in on this site, then try again.';
  }
  if (raw.contains('not installed') || raw.contains('took too long')) return raw;
  if (raw.contains('HTTP Error 404') || raw.contains('HTTP Error 410')) return 'This page does not exist.';
  if (raw.contains('HTTP Error 403') || raw.contains('HTTP Error 429')) {
    return 'The site refused the request. Try again later, or update yt-dlp.';
  }
  if (raw.contains('Unable to download') || raw.contains('Failed to resolve') || raw.contains('timed out')) {
    return 'Could not reach the site. Check your connection.';
  }
  if (raw.contains('Private video')) {
    return 'This video is private. Sign in with an account that can see it, then retry.';
  }
  if (raw.contains('unavailable')) return 'This video is unavailable.';
  return raw.length > 160 ? '${raw.substring(0, 160)}...' : raw;
}
