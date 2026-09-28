/// Pure yt-dlp command-line knowledge: which flags to pass, how to read what
/// comes back. Shared by both engine adapters; no IO here.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'engine.dart';

const _progressMark = 'TSP';
const _fileMark = 'TSF';

/// Extra flags an adapter adds for its environment (tool locations).
class EnvFlags {
  const EnvFlags({this.ffmpegPath, this.jsRuntime, this.remoteEjs = false});

  /// Directory or binary path of ffmpeg, when not on PATH.
  final String? ffmpegPath;

  /// `deno:/path/to/deno` style value for `--js-runtimes`.
  final String? jsRuntime;

  /// Fetch YouTube challenge solver scripts from GitHub when the build does
  /// not bundle them (Android's pip-style yt-dlp).
  final bool remoteEjs;

  List<String> toArgs() => [
    if (ffmpegPath != null) ...['--ffmpeg-location', ffmpegPath!],
    if (jsRuntime != null) ...['--js-runtimes', jsRuntime!],
    if (remoteEjs) ...['--remote-components', 'ejs:github'],
  ];
}

/// Network flags every run gets. yt-dlp's defaults give up on the first
/// dropped connection for extraction and retry downloads with no pause;
/// flaky mobile data needs both retries and a back-off between them.
const networkArgs = [
  '--socket-timeout',
  '30',
  '--retries',
  '10',
  '--fragment-retries',
  '10',
  '--extractor-retries',
  '5',
  '--retry-sleep',
  'http:exp=1:20',
  '--retry-sleep',
  'fragment:exp=1:20',
  '--retry-sleep',
  'extractor:exp=1:10',
];

/// Signed-in session exported from the in-app browser, when one is needed.
List<String> cookieArgs(String? cookiesFile) => cookiesFile == null ? const [] : ['--cookies', cookiesFile];

List<String> playlistArgs(String url, EnvFlags env, {String? cookiesFile}) => [
  '--flat-playlist',
  '--dump-single-json',
  '--no-warnings',
  ...networkArgs,
  ...cookieArgs(cookiesFile),
  ...env.toArgs(),
  url,
];

/// Like [playlistArgs], for any page. `--no-playlist` makes a video watched
/// inside a playlist (`watch?v=..&list=..`) mean that video; pages that only
/// are lists (channels, albums) still list their items.
List<String> probeArgs(String url, EnvFlags env, {String? cookiesFile}) => [
  '--flat-playlist',
  '--no-playlist',
  '--dump-single-json',
  '--no-warnings',
  ...networkArgs,
  ...cookieArgs(cookiesFile),
  ...env.toArgs(),
  url,
];

List<String> downloadArgs(DownloadSpec s, EnvFlags env) {
  final media = switch (s.prefs.mode) {
    MediaMode.audio => ['-f', 'bestaudio[ext=m4a]/bestaudio/best', '-x', '--audio-format', 'm4a'],
    MediaMode.video => [
      '-f',
      'bv*[height<=${s.prefs.maxHeight}]+ba/b[height<=${s.prefs.maxHeight}]/b',
      '--merge-output-format',
      'mp4',
    ],
  };
  final video = s.prefs.mode == MediaMode.video;
  return [
    ...media,
    '--no-playlist',
    '--no-mtime',
    '--embed-metadata',
    '--embed-chapters',
    ...switch (s.sponsorBlock) {
      SponsorBlock.off => const <String>[],
      SponsorBlock.mark => ['--sponsorblock-mark', 'all'],
      // SponsorBlock's own auto-skip defaults: never the content itself.
      SponsorBlock.remove => ['--sponsorblock-remove', 'sponsor,selfpromo,interaction'],
    },
    if (video && s.subtitles) ...subtitleArgs(autoCaptions: s.autoCaptions),
    '--write-thumbnail',
    '--convert-thumbnails',
    'jpg',
    '-o',
    p.join(s.outputDir, '%(title).80B [%(id)s].%(ext)s'),
    '-o',
    'thumbnail:${p.join(s.thumbsDir, '${s.fileKey}.%(ext)s')}',
    '--progress',
    '--newline',
    '--progress-template',
    'download:$_progressMark %(progress.downloaded_bytes)s %(progress.total_bytes)s '
        '%(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s',
    '--print',
    'after_move:$_fileMark%(filepath)s',
    ...networkArgs,
    // Some networks advertise IPv6 they cannot route ("Network is
    // unreachable"); a retry after such a failure goes over IPv4.
    if (s.forceIpv4) '--force-ipv4',
    ...cookieArgs(s.cookiesFile),
    ...env.toArgs(),
    s.url,
  ];
}

/// English subtitles embedded in the video, and no subtitle file left next
/// to it. yt-dlp keeps the separate file whenever `--write-subs` comes with
/// `--embed-subs`; `no-keep-subs` makes it delete the file after embedding.
/// Converted to SRT first, because MP4 cannot take WebVTT as it comes, and
/// the first track is flagged default so players show it without asking.
List<String> subtitleArgs({required bool autoCaptions}) => [
  '--write-subs',
  // YouTube's own captions when the uploader gave none. Real subtitles win
  // when a video has both.
  if (autoCaptions) '--write-auto-subs',
  '--sub-langs',
  // en, en-US, en-GB... but not the untranslated "en-orig" auto track, a
  // duplicate of "en" on YouTube.
  'en.*,-en-orig,-live_chat',
  '--convert-subs',
  'srt',
  '--embed-subs',
  '--compat-options',
  'no-keep-subs',
  '--ppa',
  'EmbedSubtitle+ffmpeg_o:-disposition:s:0 default',
];

/// A download that failed only because its subtitles could not be fetched
/// (YouTube rate-limits caption requests). Worth retrying without them.
bool isSubtitleError(String message) {
  final m = message.toLowerCase();
  return m.contains('subtitle') || m.contains('caption');
}

/// Parses one stdout line of a download; null if it is not a progress line.
DownloadProgress? parseProgressLine(String line) {
  final t = line.trim();
  if (!t.startsWith('$_progressMark ')) return null;
  final f = t.substring(_progressMark.length + 1).split(' ');
  if (f.length < 5) return null;
  double? n(String v) => double.tryParse(v);
  final done = n(f[0]);
  final total = n(f[1]) ?? n(f[2]);
  final eta = n(f[4]);
  return DownloadProgress(
    fraction: (done != null && total != null && total > 0) ? (done / total).clamp(0, 1) : null,
    speedBps: n(f[3]),
    eta: eta == null ? null : Duration(seconds: eta.round()),
  );
}

/// Finds the final media path in a download's full stdout.
String? parseFinalPath(String stdout) {
  String? found;
  for (final line in const LineSplitter().convert(stdout)) {
    final t = line.trim();
    if (t.startsWith(_fileMark)) found = t.substring(_fileMark.length);
  }
  return found;
}

/// Thumbnail location is deterministic from the `thumbnail:` output template.
String thumbPathFor(DownloadSpec s) => p.join(s.thumbsDir, '${s.fileKey}.jpg');

RemotePlaylist parsePlaylistJson(String raw) {
  final Map<String, dynamic> j;
  try {
    j = (jsonDecode(raw) as Map).cast<String, dynamic>();
  } catch (_) {
    throw EngineException('yt-dlp returned unreadable output');
  }
  final entries = <RemoteEntry>[];
  for (final e in (j['entries'] as List? ?? const [])) {
    if (e is! Map) continue;
    final id = e['id'] as String?;
    if (id == null) continue;
    final title = (e['title'] as String?) ?? id;
    final thumbs = e['thumbnails'];
    final dur = e['duration'];
    entries.add(
      RemoteEntry(
        id: id,
        title: title,
        channel: (e['channel'] ?? e['uploader']) as String?,
        duration: dur is num ? Duration(seconds: dur.round()) : null,
        thumbnailUrl: thumbs is List && thumbs.isNotEmpty ? (thumbs.last as Map)['url'] as String? : null,
        // Placeholders for removed videos: no duration and a bracketed title.
        unavailable: dur == null && RegExp(r'^\[(Private|Deleted)').hasMatch(title),
      ),
    );
  }
  return RemotePlaylist(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? 'Playlist',
    channel: (j['channel'] ?? j['uploader']) as String?,
    entries: entries,
  );
}

/// Reads `-J --flat-playlist` output for an arbitrary page. A playlist-like
/// page gives its entries; a single item gives itself, with the video
/// heights its formats offer.
ProbeResult parseProbeJson(String raw, String pageUrl) {
  final Map<String, dynamic> j;
  try {
    j = (jsonDecode(raw) as Map).cast<String, dynamic>();
  } catch (_) {
    throw EngineException('yt-dlp returned unreadable output');
  }
  final title = (j['title'] as String?) ?? pageUrl;
  if (j['_type'] == 'playlist' || j['entries'] is List) {
    final out = <RemoteEntry>[];
    for (final e in (j['entries'] as List? ?? const [])) {
      if (e is! Map) continue;
      final m = e.cast<String, dynamic>();
      final url = (m['url'] ?? m['webpage_url']) as String?;
      if (url == null) continue;
      out.add(_probeEntry(m, url));
    }
    return ProbeResult(title: title, entries: out, isPlaylist: true);
  }
  final url = (j['webpage_url'] ?? j['original_url'] ?? pageUrl) as String;
  return ProbeResult(title: title, entries: [_probeEntry(j, url)], isPlaylist: false);
}

RemoteEntry _probeEntry(Map<String, dynamic> m, String url) {
  final extractor = (m['ie_key'] ?? m['extractor_key'] ?? 'Web') as String;
  final rawId = (m['id'] ?? url).toString();
  final dur = m['duration'];
  final thumbs = m['thumbnails'];
  final heights = <int>{
    for (final f in (m['formats'] as List? ?? const []))
      if (f is Map && f['vcodec'] != 'none' && f['height'] is num) (f['height'] as num).toInt(),
  }.toList()..sort();
  return RemoteEntry(
    // YouTube ids stay bare so a grab and a tracked playlist agree on identity.
    id: extractor == 'Youtube' ? rawId : '$extractor:$rawId',
    title: (m['title'] as String?) ?? url,
    channel: (m['channel'] ?? m['uploader']) as String?,
    duration: dur is num ? Duration(seconds: dur.round()) : null,
    thumbnailUrl:
        (m['thumbnail'] as String?) ??
        (thumbs is List && thumbs.isNotEmpty ? (thumbs.last as Map)['url'] as String? : null),
    url: url,
    heights: heights,
  );
}

/// Turns yt-dlp's stderr into one line worth showing a person.
String summariseError(String stderr) {
  final lines = const LineSplitter().convert(stderr).map((l) => l.trim()).where((l) => l.startsWith('ERROR:')).toList();
  if (lines.isEmpty) {
    final any = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty);
    return any.isEmpty ? 'yt-dlp failed' : any.last.trim();
  }
  return lines.last.replaceFirst('ERROR:', '').trim();
}

/// The site wants a signed-in user: private, members-only, age-gated, or
/// YouTube's "confirm you're not a bot" wall. Browser cookies can fix it.
bool isAuthError(String message) {
  final m = message.toLowerCase();
  return const [
    'private video',
    'sign in',
    'login required',
    'log in',
    'logged-in',
    'cookies',
    'members-only',
    'members only',
    'join this channel',
    'age-restricted',
    'confirm your age',
    'inappropriate for some users',
    'not a bot',
    'account',
  ].any(m.contains);
}

/// A failure worth trying again unchanged: the network, not the video.
bool isTransientError(String message) {
  final m = message.toLowerCase();
  return const [
    'unreachable',
    'unable to download',
    'timed out',
    'timeout',
    'connection reset',
    'connection refused',
    'connection aborted',
    'remote end closed',
    'temporary failure',
    'failed to resolve',
    'name or service not known',
    'getaddrinfo',
    'no address associated',
    'incompleteread',
    'incomplete read',
    'ssl',
    'eof occurred',
    'http error 5',
    'http error 429',
    'http error 403',
    'errno',
    'network',
    'fragment',
    'did not get any data',
    'giving up after',
  ].any(m.contains);
}

/// The failure mentioned IPv6 routing, or a plain "unreachable".
bool isRoutingError(String message) {
  final m = message.toLowerCase();
  return m.contains('unreachable') || m.contains('errno 101') || m.contains('no route to host');
}
