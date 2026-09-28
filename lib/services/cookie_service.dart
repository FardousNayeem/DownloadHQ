import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:webview_all/webview_all.dart';

import '../domain/adblock.dart' show siteOf;
import '../domain/models.dart';
import '../engine/engine.dart';
import '../engine/ytdlp_cli.dart' show isAuthError, isTransientError;

/// Shares the in-app browser's sign-in with yt-dlp. Sign in to YouTube (or
/// any site) in the Browse tab once, and private, members-only and
/// age-restricted videos download with that account.
///
/// Only used after a download fails for want of a sign-in: YouTube rotates
/// session cookies it sees used elsewhere, and doing that on every run would
/// keep signing the browser out.
class CookieService {
  CookieService(this._dir, {this._userFile});

  final String _dir;

  /// A cookies.txt the user picked in Settings; tried before the browser.
  final String? Function()? _userFile;
  late final _manager = WebViewCookieManager();
  var _n = 0;

  /// Writes the browser's cookies for [url]'s site to a fresh Netscape
  /// cookies file and returns its path, or null when the browser holds none
  /// (not signed in there). The caller deletes the file with [release].
  Future<String?> exportFor(String url) async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return null;
    final picked = _userFile?.call();
    if (picked != null && await File(picked).exists()) {
      // yt-dlp writes cookies back when it exits; hand it a copy so the
      // user's file stays as they exported it.
      await Directory(_dir).create(recursive: true);
      final copy = p.join(_dir, 'cookies-${DateTime.now().microsecondsSinceEpoch}-${_n++}.txt');
      return (await File(picked).copy(copy)).path;
    }
    final origins = _originsFor(host);
    final lines = <String>{};
    for (final o in origins) {
      List<WebViewCookie> cookies;
      try {
        cookies = await _manager.getCookies(domain: Uri.parse(o));
      } catch (e) {
        debugPrint('DownloadHQ: cookies for $o: $e');
        continue;
      }
      for (final c in cookies) {
        if (c.name.isEmpty) continue;
        lines.add(netscapeLine(c, siteOf(Uri.parse(o).host)));
      }
    }
    if (lines.isEmpty) return null;
    await Directory(_dir).create(recursive: true);
    final f = File(p.join(_dir, 'cookies-${DateTime.now().microsecondsSinceEpoch}-${_n++}.txt'));
    await f.writeAsString('# Netscape HTTP Cookie File\n${lines.join('\n')}\n', flush: true);
    return f.path;
  }

  /// Deletes a file from [exportFor]. It holds a live session; it must not
  /// linger on disk.
  Future<void> release(String? path) async {
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// Removes files a crash left behind.
  Future<void> sweep() async {
    try {
      await for (final e in Directory(_dir).list()) {
        if (e is File && p.basename(e.path).startsWith('cookies-')) await e.delete();
      }
    } catch (_) {}
  }

  /// youtu.be links and YouTube Music share the youtube.com session.
  static List<String> _originsFor(String host) {
    final site = siteOf(host);
    if (site == 'youtube.com' || site == 'youtu.be' || site == 'youtube-nocookie.com') {
      return const ['https://www.youtube.com', 'https://m.youtube.com', 'https://music.youtube.com'];
    }
    return ['https://$host', if (host != site) 'https://$site', 'https://www.$site'];
  }
}

/// One cookie in the Netscape format yt-dlp reads. The browser APIs do not
/// report expiry or flags, so the cookie is scoped to the whole [site],
/// secure, and valid for a year (yt-dlp ignores expiry when loading anyway).
@visibleForTesting
String netscapeLine(WebViewCookie c, String site) {
  final expires = DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000;
  final path = c.path.isEmpty ? '/' : c.path;
  // Tabs and newlines would break the line format.
  String clean(String s) => s.replaceAll(RegExp(r'[\t\r\n]'), '');
  return ['.$site', 'TRUE', path, 'TRUE', '$expires', clean(c.name), clean(c.value)].join('\t');
}

/// Wraps an engine so listing a page or playlist that needs a sign-in
/// (private playlist, Liked videos, members-only video) retries once with
/// the browser's cookies, and a network hiccup gets one more try.
/// Downloads pass through; [DownloadQueue] retries those itself.
class SignInFallbackEngine implements YtDlpEngine {
  SignInFallbackEngine(this._inner, this._cookies);

  final YtDlpEngine _inner;
  final CookieService _cookies;

  Future<T> _withFallback<T>(String url, Future<T> Function(String? cookies) run) async {
    try {
      return await run(null);
    } on EngineException catch (e) {
      if (isAuthError(e.message)) {
        final file = await _cookies.exportFor(url);
        if (file == null) rethrow;
        try {
          return await run(file);
        } finally {
          await _cookies.release(file);
        }
      }
      if (isTransientError(e.message)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        return run(null);
      }
      rethrow;
    }
  }

  @override
  Future<RemotePlaylist> fetchPlaylist(String url, {String? cookiesFile}) =>
      _withFallback(url, (c) => _inner.fetchPlaylist(url, cookiesFile: cookiesFile ?? c));

  @override
  Future<ProbeResult> probe(String url, {String? cookiesFile}) =>
      _withFallback(url, (c) => _inner.probe(url, cookiesFile: cookiesFile ?? c));

  @override
  DownloadTask download(DownloadSpec spec) => _inner.download(spec);

  @override
  Future<EngineStatus> status() => _inner.status();

  @override
  Future<String> updateYtDlp() => _inner.updateYtDlp();
}
