import 'package:flutter/material.dart' show ThemeMode;

import '../domain/models.dart';
import 'json_store.dart';

/// Where playlists live. Interface so a database can replace JSON later
/// without touching services.
abstract interface class LibraryRepository {
  Future<List<Playlist>> load();
  Future<void> save(List<Playlist> playlists);
}

class JsonLibraryRepository implements LibraryRepository {
  JsonLibraryRepository(this._store);
  final JsonStore _store;

  @override
  Future<List<Playlist>> load() async {
    final j = await _store.read();
    if (j is! Map) return [];
    try {
      return [
        for (final p in (j['playlists'] as List? ?? const [])) Playlist.fromJson((p as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      // Valid JSON, wrong shape (hand edits, a future version's file).
      await _store.quarantine();
      return [];
    }
  }

  @override
  Future<void> save(List<Playlist> playlists) => _store.write({
    'version': 1,
    'playlists': [for (final p in playlists) p.toJson()],
  });
}

class AppSettings {
  const AppSettings({
    required this.downloadDir,
    this.parallelDownloads = 2,
    this.checkEveryHours = 6,
    this.themeMode = ThemeMode.system,
    this.lastGrabMode = MediaMode.video,
    this.homePage,
    this.sponsorBlock = SponsorBlock.off,
    this.embedSubtitles = false,
  });

  final String downloadDir;
  final int parallelDownloads;

  /// While the app is open, re-sync all playlists this often. 0 = only on launch.
  final int checkEveryHours;
  final ThemeMode themeMode;

  /// Audio or video, remembered between grabs from the browser.
  final MediaMode lastGrabMode;

  /// First page the browser opens. Null means [defaultHomePage].
  final String? homePage;

  /// Sponsor segments in YouTube downloads (community data from
  /// sponsor.ajay.app, applied by yt-dlp).
  final SponsorBlock sponsorBlock;

  /// Video downloads carry the uploader's subtitles, when there are any.
  final bool embedSubtitles;

  static const defaultHomePage = 'https://duckduckgo.com/';

  String get home => homePage ?? defaultHomePage;

  static const _keep = Object();

  AppSettings copyWith({
    String? downloadDir,
    int? parallelDownloads,
    int? checkEveryHours,
    ThemeMode? themeMode,
    MediaMode? lastGrabMode,
    Object? homePage = _keep,
    SponsorBlock? sponsorBlock,
    bool? embedSubtitles,
  }) => AppSettings(
    downloadDir: downloadDir ?? this.downloadDir,
    parallelDownloads: parallelDownloads ?? this.parallelDownloads,
    checkEveryHours: checkEveryHours ?? this.checkEveryHours,
    themeMode: themeMode ?? this.themeMode,
    lastGrabMode: lastGrabMode ?? this.lastGrabMode,
    homePage: identical(homePage, _keep) ? this.homePage : homePage as String?,
    sponsorBlock: sponsorBlock ?? this.sponsorBlock,
    embedSubtitles: embedSubtitles ?? this.embedSubtitles,
  );

  Map<String, dynamic> toJson() => {
    'downloadDir': downloadDir,
    'parallelDownloads': parallelDownloads,
    'checkEveryHours': checkEveryHours,
    'themeMode': themeMode.name,
    'lastGrabMode': lastGrabMode.name,
    'homePage': homePage,
    'sponsorBlock': sponsorBlock.name,
    'embedSubtitles': embedSubtitles,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j, String defaultDir) => AppSettings(
    downloadDir: j['downloadDir'] as String? ?? defaultDir,
    parallelDownloads: j['parallelDownloads'] as int? ?? 2,
    checkEveryHours: j['checkEveryHours'] as int? ?? 6,
    themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
    lastGrabMode: MediaMode.values.asNameMap()[j['lastGrabMode']] ?? MediaMode.video,
    homePage: j['homePage'] as String?,
    sponsorBlock: SponsorBlock.values.asNameMap()[j['sponsorBlock']] ?? SponsorBlock.off,
    embedSubtitles: j['embedSubtitles'] as bool? ?? false,
  );
}

class SettingsRepository {
  SettingsRepository(this._store, this.defaultDownloadDir);
  final JsonStore _store;
  final String defaultDownloadDir;

  Future<AppSettings> load() async {
    final j = await _store.read();
    try {
      if (j is Map) return AppSettings.fromJson(j.cast<String, dynamic>(), defaultDownloadDir);
    } catch (_) {
      await _store.quarantine();
    }
    return AppSettings(downloadDir: defaultDownloadDir);
  }

  Future<void> save(AppSettings s) => _store.write(s.toJson());
}
