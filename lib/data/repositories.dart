import 'package:flutter/material.dart' show ThemeMode;

import '../domain/models.dart';
import '../domain/subtitles.dart';
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
    this.subtitleMode = SubtitleMode.embed,
    this.autoCaptions = true,
    this.cookiesFile,
    this.autoUpdateYtDlp = true,
    this.lastYtDlpUpdate,
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

  /// What happens to English subtitles of video downloads.
  final SubtitleMode subtitleMode;

  /// Use YouTube's automatic captions when a video has no real subtitles.
  final bool autoCaptions;

  /// A cookies.txt the user exported from a desktop browser. Used for
  /// sign-in walls before the in-app browser's own cookies.
  final String? cookiesFile;

  /// Update yt-dlp by itself once a day. Sites change often; an old yt-dlp
  /// is the usual reason downloads start failing.
  final bool autoUpdateYtDlp;
  final DateTime? lastYtDlpUpdate;

  static const defaultHomePage = 'https://m.youtube.com';

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
    SubtitleMode? subtitleMode,
    bool? autoCaptions,
    Object? cookiesFile = _keep,
    bool? autoUpdateYtDlp,
    DateTime? lastYtDlpUpdate,
  }) => AppSettings(
    downloadDir: downloadDir ?? this.downloadDir,
    parallelDownloads: parallelDownloads ?? this.parallelDownloads,
    checkEveryHours: checkEveryHours ?? this.checkEveryHours,
    themeMode: themeMode ?? this.themeMode,
    lastGrabMode: lastGrabMode ?? this.lastGrabMode,
    homePage: identical(homePage, _keep) ? this.homePage : homePage as String?,
    sponsorBlock: sponsorBlock ?? this.sponsorBlock,
    subtitleMode: subtitleMode ?? this.subtitleMode,
    autoCaptions: autoCaptions ?? this.autoCaptions,
    cookiesFile: identical(cookiesFile, _keep) ? this.cookiesFile : cookiesFile as String?,
    autoUpdateYtDlp: autoUpdateYtDlp ?? this.autoUpdateYtDlp,
    lastYtDlpUpdate: lastYtDlpUpdate ?? this.lastYtDlpUpdate,
  );

  Map<String, dynamic> toJson() => {
    'downloadDir': downloadDir,
    'parallelDownloads': parallelDownloads,
    'checkEveryHours': checkEveryHours,
    'themeMode': themeMode.name,
    'lastGrabMode': lastGrabMode.name,
    'homePage': homePage,
    'sponsorBlock': sponsorBlock.name,
    'subtitleMode': subtitleMode.name,
    'autoCaptions': autoCaptions,
    'cookiesFile': cookiesFile,
    'autoUpdateYtDlp': autoUpdateYtDlp,
    'lastYtDlpUpdate': lastYtDlpUpdate?.toIso8601String(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> j, String defaultDir) => AppSettings(
    downloadDir: j['downloadDir'] as String? ?? defaultDir,
    parallelDownloads: j['parallelDownloads'] as int? ?? 2,
    checkEveryHours: j['checkEveryHours'] as int? ?? 6,
    themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
    lastGrabMode: MediaMode.values.asNameMap()[j['lastGrabMode']] ?? MediaMode.video,
    homePage: j['homePage'] as String?,
    sponsorBlock: SponsorBlock.values.asNameMap()[j['sponsorBlock']] ?? SponsorBlock.off,
    subtitleMode:
        SubtitleMode.values.asNameMap()[j['subtitleMode']] ??
        // Before modes there was one switch; an explicit "off" stays off.
        (j['embedSubtitles'] == false ? SubtitleMode.off : SubtitleMode.embed),
    autoCaptions: j['autoCaptions'] as bool? ?? true,
    cookiesFile: j['cookiesFile'] as String?,
    autoUpdateYtDlp: j['autoUpdateYtDlp'] as bool? ?? true,
    lastYtDlpUpdate: DateTime.tryParse(j['lastYtDlpUpdate'] as String? ?? ''),
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
