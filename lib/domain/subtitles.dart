/// Pure subtitle knowledge: which files next to a video are its subtitles,
/// and the ffmpeg arguments that put them inside it. No IO here.
library;

import 'package:path/path.dart' as p;

/// Where downloaded subtitles end up.
enum SubtitleMode {
  off('Off'),
  embed('Inside the video'),
  burn('Burned into the picture');

  const SubtitleMode(this.label);
  final String label;
}

const subtitleExtensions = {'.srt', '.vtt', '.ass', '.ssa'};

/// A subtitle file yt-dlp wrote next to a video: `<video stem>.<lang>.<ext>`.
class SidecarSub {
  const SidecarSub(this.path, this.lang);
  final String path;

  /// As yt-dlp names it: `en`, `en-US`, `en-orig`...
  final String lang;
}

/// Picks the subtitle files that belong to [videoPath] out of the names in
/// its folder ([siblings], full paths). English first.
List<SidecarSub> sidecarsFor(String videoPath, Iterable<String> siblings) {
  final stem = p.basenameWithoutExtension(videoPath);
  final out = <SidecarSub>[];
  for (final s in siblings) {
    final ext = p.extension(s).toLowerCase();
    if (!subtitleExtensions.contains(ext)) continue;
    final name = p.basenameWithoutExtension(s);
    if (!name.startsWith('$stem.')) continue;
    final lang = name.substring(stem.length + 1);
    // Language tags only; "My video.part2.srt" style names are not ours.
    if (!RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$').hasMatch(lang)) continue;
    out.add(SidecarSub(s, lang));
  }
  out.sort((a, b) => (_isEnglish(b.lang) ? 1 : 0) - (_isEnglish(a.lang) ? 1 : 0));
  return out;
}

bool _isEnglish(String lang) => lang.toLowerCase().startsWith('en');

/// ISO 639-2 code for a subtitle stream's language tag (what players show).
String iso639_2(String lang) {
  final base = lang.split('-').first.toLowerCase();
  return const {
        'en': 'eng',
        'bn': 'ben',
        'hi': 'hin',
        'ar': 'ara',
        'es': 'spa',
        'fr': 'fra',
        'de': 'deu',
        'pt': 'por',
        'ru': 'rus',
        'ja': 'jpn',
        'ko': 'kor',
        'zh': 'zho',
        'ur': 'urd',
        'id': 'ind',
        'tr': 'tur',
        'it': 'ita',
      }[base] ??
      (base.length == 3 ? base : 'und');
}

/// Subtitle codec each container accepts.
String subtitleCodecFor(String videoPath) => switch (p.extension(videoPath).toLowerCase()) {
  '.mp4' || '.m4v' || '.mov' => 'mov_text',
  '.webm' => 'webvtt',
  _ => 'srt',
};

/// Copies [videoPath] to [outPath] with [subs] added as subtitle tracks, the
/// first one shown by default. Picture and sound are copied, not re-encoded,
/// so this takes seconds.
List<String> mergeSubsArgs(String videoPath, List<SidecarSub> subs, String outPath) {
  return [
    '-hide_banner',
    '-nostdin',
    '-y',
    '-i',
    videoPath,
    for (final s in subs) ...['-i', s.path],
    '-map',
    '0:v',
    '-map',
    '0:a?',
    for (var i = 0; i < subs.length; i++) ...['-map', '${i + 1}:0'],
    '-map_metadata',
    '0',
    '-map_chapters',
    '0',
    '-c',
    'copy',
    '-c:s',
    subtitleCodecFor(videoPath),
    for (var i = 0; i < subs.length; i++) ...[
      '-metadata:s:s:$i',
      'language=${iso639_2(subs[i].lang)}',
      '-metadata:s:s:$i',
      'title=${subtitleTitle(subs[i].lang)}',
      '-disposition:s:$i',
      i == 0 ? 'default' : '0',
    ],
    if (p.extension(videoPath).toLowerCase() == '.mp4') ...['-movflags', '+faststart'],
    outPath,
  ];
}

String subtitleTitle(String lang) {
  final l = lang.toLowerCase();
  final name = l.startsWith('en') ? 'English' : lang;
  return l.endsWith('-orig') ? '$name (automatic)' : name;
}

/// Pulls the first subtitle track of [videoPath] out as `sub.srt` in the
/// working directory (for burning in).
List<String> extractSubArgs(String videoPath) => [
  '-hide_banner',
  '-nostdin',
  '-y',
  '-i',
  videoPath,
  '-map',
  '0:s:0',
  'sub.srt',
];

/// Draws `sub.srt` (in the working directory, so no path escaping is needed
/// inside the filter) onto the picture. Re-encodes the video; sound is copied.
List<String> burnSubsArgs(String videoPath, String outPath) => [
  '-hide_banner',
  '-nostdin',
  '-y',
  '-i',
  videoPath,
  '-map',
  '0:v:0',
  '-map',
  '0:a?',
  '-vf',
  'subtitles=sub.srt:force_style=FontSize=22,Outline=2',
  '-c:v',
  'libx264',
  '-preset',
  'veryfast',
  '-crf',
  '21',
  '-c:a',
  'copy',
  '-map_metadata',
  '0',
  '-map_chapters',
  '0',
  '-movflags',
  '+faststart',
  '-progress',
  'pipe:1',
  '-nostats',
  outPath,
];

/// Reads `out_time_ms=` lines of `-progress pipe:1` (microseconds, despite
/// the name). Null for other lines.
Duration? parseFfmpegProgress(String line) {
  final m = RegExp(r'^out_time_(?:ms|us)=(\d+)').firstMatch(line.trim());
  return m == null ? null : Duration(microseconds: int.parse(m.group(1)!));
}
