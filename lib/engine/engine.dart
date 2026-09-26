import '../domain/models.dart';

/// What the rest of the app needs from yt-dlp. Two adapters implement it:
/// [ProcessEngine] (desktop, spawns the binary) and [AndroidEngine] (platform
/// channel over youtubedl-android). Nothing above this line knows which.
abstract interface class YtDlpEngine {
  /// Tool availability, for the settings screen and for gating actions.
  Future<EngineStatus> status();

  /// Lists a playlist without downloading anything (`--flat-playlist -J`).
  Future<RemotePlaylist> fetchPlaylist(String url);

  /// Asks yt-dlp what it can download from any page: one item, or the
  /// entries of a playlist-like page. Throws [EngineException] when the
  /// page has nothing yt-dlp understands.
  Future<ProbeResult> probe(String url);

  /// Starts one download. Never throws synchronously; failures arrive
  /// through [DownloadTask.result].
  DownloadTask download(DownloadSpec spec);

  /// Replaces yt-dlp with the latest release. Returns the new version.
  Future<String> updateYtDlp();
}

class DownloadSpec {
  const DownloadSpec({
    required this.url,
    required this.fileKey,
    required this.prefs,
    required this.outputDir,
    required this.thumbsDir,
    this.sponsorBlock = SponsorBlock.off,
    this.subtitles = false,
  });

  final String url;

  /// Names the thumbnail file; unique per entry and safe on every OS.
  final String fileKey;
  final DownloadPrefs prefs;
  final String outputDir;
  final String thumbsDir;
  final SponsorBlock sponsorBlock;

  /// Embed the uploader's subtitles (video only).
  final bool subtitles;
}

class ProbeResult {
  const ProbeResult({required this.title, required this.entries, required this.isPlaylist});

  final String title;
  final List<RemoteEntry> entries;
  final bool isPlaylist;
}

class DownloadProgress {
  const DownloadProgress({this.fraction, this.speedBps, this.eta});

  /// 0..1, null when size is unknown.
  final double? fraction;
  final double? speedBps;
  final Duration? eta;
}

class DownloadedFile {
  const DownloadedFile({required this.filePath, this.thumbPath});
  final String filePath;
  final String? thumbPath;
}

abstract interface class DownloadTask {
  Stream<DownloadProgress> get progress;
  Future<DownloadedFile> get result;
  void cancel();
}

class EngineStatus {
  const EngineStatus({required this.tools});

  final List<ToolStatus> tools;

  bool get ready => tools.where((t) => t.required).every((t) => t.found);
}

class ToolStatus {
  const ToolStatus({
    required this.name,
    required this.purpose,
    required this.found,
    this.version,
    this.path,
    this.required = true,
    this.installable = false,
  });

  final String name;
  final String purpose;
  final bool found;
  final String? version;
  final String? path;
  final bool required;

  /// The app can fetch it by itself (desktop tool installer).
  final bool installable;
}

class EngineException implements Exception {
  EngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}
