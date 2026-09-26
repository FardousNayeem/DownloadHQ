/// Plain domain types. No Flutter, no IO: everything here is serialisable and
/// testable in isolation.
library;

enum MediaMode { audio, video }

/// What happens to sponsor segments in YouTube downloads (community data
/// from sponsor.ajay.app, applied by yt-dlp; other sites are unaffected).
enum SponsorBlock {
  off('Off'),
  mark('Mark as chapters'),
  remove('Cut out');

  const SponsorBlock(this.label);
  final String label;
}

/// Per-playlist download preferences.
class DownloadPrefs {
  const DownloadPrefs({this.mode = MediaMode.audio, this.maxHeight = 720, this.autoDownloadNew = false});

  final MediaMode mode;

  /// Video only: cap on resolution (e.g. 480, 720, 1080).
  final int maxHeight;

  /// When a sync finds new entries, queue them without asking.
  final bool autoDownloadNew;

  DownloadPrefs copyWith({MediaMode? mode, int? maxHeight, bool? autoDownloadNew}) => DownloadPrefs(
    mode: mode ?? this.mode,
    maxHeight: maxHeight ?? this.maxHeight,
    autoDownloadNew: autoDownloadNew ?? this.autoDownloadNew,
  );

  Map<String, dynamic> toJson() => {'mode': mode.name, 'maxHeight': maxHeight, 'autoDownloadNew': autoDownloadNew};

  factory DownloadPrefs.fromJson(Map<String, dynamic> j) => DownloadPrefs(
    mode: MediaMode.values.asNameMap()[j['mode']] ?? MediaMode.audio,
    maxHeight: j['maxHeight'] as int? ?? 720,
    autoDownloadNew: j['autoDownloadNew'] as bool? ?? false,
  );
}

/// One video as the remote playlist currently lists it (output of a flat fetch).
class RemoteEntry {
  const RemoteEntry({
    required this.id,
    required this.title,
    this.channel,
    this.duration,
    this.thumbnailUrl,
    this.unavailable = false,
    this.url,
    this.heights = const [],
  });

  final String id;
  final String title;
  final String? channel;
  final Duration? duration;
  final String? thumbnailUrl;

  /// Private / deleted videos still appear in playlists as placeholders.
  final bool unavailable;

  /// Page to hand yt-dlp. Null means a YouTube video addressed by [id].
  final String? url;

  /// Video heights on offer, known only when a single item was probed.
  final List<int> heights;
}

class RemotePlaylist {
  const RemotePlaylist({required this.id, required this.title, this.channel, required this.entries});

  final String id;
  final String title;
  final String? channel;
  final List<RemoteEntry> entries;
}

/// One video as the local library knows it. Survives removal from the remote
/// playlist: once downloaded, a file is the user's, whatever YouTube does.
class Entry {
  const Entry({
    required this.id,
    required this.title,
    required this.position,
    required this.firstSeen,
    this.channel,
    this.duration,
    this.thumbnailUrl,
    this.isNew = false,
    this.ignored = false,
    this.unavailable = false,
    this.removedFromSource = false,
    this.filePath,
    this.thumbPath,
    this.lastError,
    this.sourceUrl,
    this.prefs,
  });

  final String id;
  final String title;
  final String? channel;
  final Duration? duration;
  final String? thumbnailUrl;

  /// Index in the remote playlist at last sync.
  final int position;
  final DateTime firstSeen;

  /// Appeared in a sync after the first one and the user has not dealt with it.
  final bool isNew;

  /// User said "don't want this one"; hidden from pending lists.
  final bool ignored;
  final bool unavailable;
  final bool removedFromSource;

  /// Local media file once downloaded.
  final String? filePath;
  final String? thumbPath;
  final String? lastError;

  /// Where to download from when this is not a YouTube video id.
  final String? sourceUrl;

  /// Overrides the playlist's prefs (items grabbed from the web pick their own).
  final DownloadPrefs? prefs;

  String get downloadUrl => sourceUrl ?? 'https://www.youtube.com/watch?v=$id';

  /// File-name-safe form of [id] (web ids look like `Vimeo:123`).
  String get fileKey => id.replaceAll(RegExp(r'[^\w-]'), '_');

  bool get isDownloaded => filePath != null;
  bool get isPending => !isDownloaded && !ignored && !unavailable;

  static const _keep = Object();

  Entry copyWith({
    String? title,
    String? channel,
    Duration? duration,
    String? thumbnailUrl,
    int? position,
    bool? isNew,
    bool? ignored,
    bool? unavailable,
    bool? removedFromSource,
    Object? filePath = _keep,
    Object? thumbPath = _keep,
    Object? lastError = _keep,
  }) => Entry(
    id: id,
    firstSeen: firstSeen,
    title: title ?? this.title,
    channel: channel ?? this.channel,
    duration: duration ?? this.duration,
    thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    position: position ?? this.position,
    isNew: isNew ?? this.isNew,
    ignored: ignored ?? this.ignored,
    unavailable: unavailable ?? this.unavailable,
    removedFromSource: removedFromSource ?? this.removedFromSource,
    filePath: identical(filePath, _keep) ? this.filePath : filePath as String?,
    thumbPath: identical(thumbPath, _keep) ? this.thumbPath : thumbPath as String?,
    lastError: identical(lastError, _keep) ? this.lastError : lastError as String?,
    sourceUrl: sourceUrl,
    prefs: prefs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'channel': channel,
    'durationS': duration?.inSeconds,
    'thumbnailUrl': thumbnailUrl,
    'position': position,
    'firstSeen': firstSeen.toIso8601String(),
    'isNew': isNew,
    'ignored': ignored,
    'unavailable': unavailable,
    'removedFromSource': removedFromSource,
    'filePath': filePath,
    'thumbPath': thumbPath,
    'lastError': lastError,
    'sourceUrl': sourceUrl,
    'prefs': prefs?.toJson(),
  };

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    channel: j['channel'] as String?,
    duration: j['durationS'] == null ? null : Duration(seconds: j['durationS'] as int),
    thumbnailUrl: j['thumbnailUrl'] as String?,
    position: j['position'] as int? ?? 0,
    firstSeen: DateTime.tryParse(j['firstSeen'] as String? ?? '') ?? DateTime(2000),
    isNew: j['isNew'] as bool? ?? false,
    ignored: j['ignored'] as bool? ?? false,
    unavailable: j['unavailable'] as bool? ?? false,
    removedFromSource: j['removedFromSource'] as bool? ?? false,
    filePath: j['filePath'] as String?,
    thumbPath: j['thumbPath'] as String?,
    lastError: j['lastError'] as String?,
    sourceUrl: j['sourceUrl'] as String?,
    prefs: j['prefs'] == null ? null : DownloadPrefs.fromJson((j['prefs'] as Map).cast<String, dynamic>()),
  );
}

class Playlist {
  const Playlist({
    required this.id,
    required this.url,
    required this.title,
    required this.entries,
    this.channel,
    this.prefs = const DownloadPrefs(),
    this.lastSynced,
    this.lastSyncError,
  });

  /// Id of the collection that holds items grabbed while browsing.
  static const webId = 'web';

  /// YouTube playlist id (the `list=` value), or [webId]. Also the storage key.
  final String id;
  final String url;
  final String title;
  final String? channel;
  final DownloadPrefs prefs;
  final List<Entry> entries;
  final DateTime? lastSynced;
  final String? lastSyncError;

  /// Grabbed-from-the-web collection: never synced, has no remote.
  bool get isWeb => id == webId;

  int get newCount => entries.where((e) => e.isNew && e.isPending).length;
  int get downloadedCount => entries.where((e) => e.isDownloaded).length;
  int get pendingCount => entries.where((e) => e.isPending).length;

  Entry? entry(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  static const _keep = Object();

  Playlist copyWith({
    String? title,
    String? channel,
    DownloadPrefs? prefs,
    List<Entry>? entries,
    DateTime? lastSynced,
    Object? lastSyncError = _keep,
  }) => Playlist(
    id: id,
    url: url,
    title: title ?? this.title,
    channel: channel ?? this.channel,
    prefs: prefs ?? this.prefs,
    entries: entries ?? this.entries,
    lastSynced: lastSynced ?? this.lastSynced,
    lastSyncError: identical(lastSyncError, _keep) ? this.lastSyncError : lastSyncError as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'channel': channel,
    'prefs': prefs.toJson(),
    'lastSynced': lastSynced?.toIso8601String(),
    'lastSyncError': lastSyncError,
    'entries': [for (final e in entries) e.toJson()],
  };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: j['id'] as String,
    url: j['url'] as String,
    title: j['title'] as String? ?? 'Playlist',
    channel: j['channel'] as String?,
    prefs: DownloadPrefs.fromJson((j['prefs'] as Map?)?.cast<String, dynamic>() ?? {}),
    lastSynced: DateTime.tryParse(j['lastSynced'] as String? ?? ''),
    lastSyncError: j['lastSyncError'] as String?,
    entries: [for (final e in (j['entries'] as List? ?? const [])) Entry.fromJson((e as Map).cast<String, dynamic>())],
  );
}

/// Extracts the `list=` id from anything a user might paste.
String? parsePlaylistId(String input) {
  final s = input.trim();
  final uri = Uri.tryParse(s);
  final fromQuery = uri?.queryParameters['list'];
  if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
  // Bare id pasted (PL..., UU..., OL..., FL..., RD...).
  if (RegExp(r'^(PL|UU|OL|FL|RD|LL)[\w-]{10,}$').hasMatch(s)) return s;
  return null;
}

String canonicalPlaylistUrl(String id) => 'https://www.youtube.com/playlist?list=$id';
