import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import '../domain/subtitles.dart';
import '../engine/ffmpeg.dart';
import 'library_service.dart';
import 'playback_service.dart';

/// Puts subtitles inside saved videos, so any player shows them without
/// hunting for a separate file: after each download, and on request for
/// everything already saved.
class SubtitleService extends ChangeNotifier {
  SubtitleService(this._ffmpeg, this._library, this._playback);

  final FfmpegRunner _ffmpeg;
  final LibraryService _library;
  final PlaybackService _playback;

  bool get canBurn => _ffmpeg.canBurn;

  /// Library-wide merge in progress: how far, and the outcome when done.
  bool busy = false;
  int done = 0;
  int total = 0;
  String? message;

  /// After a download: merges any subtitle file yt-dlp left beside the
  /// video, then burns the subtitles in when [mode] asks for it and this
  /// platform can. Returns the final path (burning in can change the
  /// extension). Never throws: a failure leaves the download as it is.
  Future<String> finishDownload(
    String videoPath,
    SubtitleMode mode, {
    Duration? duration,
    void Function(double? fraction)? onBurnProgress,
  }) async {
    if (mode == SubtitleMode.off || !isVideoPath(videoPath)) return videoPath;
    try {
      await mergeSidecars(videoPath);
    } catch (e) {
      debugPrint('DownloadHQ: merging subtitles into $videoPath: $e');
    }
    if (mode != SubtitleMode.burn || !canBurn) return videoPath;
    try {
      return await burnIn(videoPath, duration: duration, onProgress: onBurnProgress) ?? videoPath;
    } catch (e) {
      debugPrint('DownloadHQ: burning subtitles into $videoPath: $e');
      return videoPath;
    }
  }

  /// Merges `<video>.<lang>.srt|vtt` files into the video and deletes them.
  /// Returns how many subtitle files went in (0: none found).
  Future<int> mergeSidecars(String videoPath) async {
    final dir = Directory(p.dirname(videoPath));
    if (!await dir.exists()) return 0;
    final siblings = [
      await for (final e in dir.list())
        if (e is File) e.path,
    ];
    final subs = sidecarsFor(videoPath, siblings);
    if (subs.isEmpty) return 0;
    final tmp = p.join(dir.path, '${p.basenameWithoutExtension(videoPath)}.subs-tmp${p.extension(videoPath)}');
    try {
      await _ffmpeg.run(mergeSubsArgs(videoPath, subs, tmp));
      await _replace(videoPath, tmp);
    } finally {
      final t = File(tmp);
      if (await t.exists()) await t.delete();
    }
    for (final s in subs) {
      try {
        await File(s.path).delete();
      } catch (_) {}
    }
    return subs.length;
  }

  /// Draws the video's first subtitle track onto the picture. Slow: the
  /// whole video is re-encoded. Returns the new path, or null when the
  /// video has no subtitles to burn.
  Future<String?> burnIn(String videoPath, {Duration? duration, void Function(double? fraction)? onProgress}) async {
    final work = await Directory.systemTemp.createTemp('dhq-burn');
    try {
      try {
        await _ffmpeg.run(extractSubArgs(videoPath), workingDir: work.path);
      } catch (_) {
        return null; // no subtitle track
      }
      if (!await File(p.join(work.path, 'sub.srt')).exists()) return null;
      final out = p.join(work.path, 'out.mp4');
      await _ffmpeg.run(
        burnSubsArgs(videoPath, out),
        workingDir: work.path,
        onLine: (l) {
          final t = parseFfmpegProgress(l);
          if (t != null && duration != null && duration > Duration.zero) {
            onProgress?.call((t.inMilliseconds / duration.inMilliseconds).clamp(0, 1).toDouble());
          }
        },
      );
      // Burned videos are always MP4 (H.264 plays everywhere).
      final target = p.setExtension(videoPath, '.mp4');
      await _replace(videoPath, out, target: target);
      return target;
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Puts [fresh] where [original] was (or at [target]), without a moment
  /// where neither exists under the final name for long.
  Future<void> _replace(String original, String fresh, {String? target}) async {
    final dest = target ?? original;
    final backup = '$original.old';
    await File(original).rename(backup);
    try {
      try {
        await File(fresh).rename(dest); // same disk: instant
      } on FileSystemException {
        await File(fresh).copy(dest); // temp dir on another disk
      }
    } catch (e) {
      await File(backup).rename(original);
      rethrow;
    }
    await File(backup).delete();
  }

  /// Merges leftover subtitle files into every saved video in the library.
  /// Videos in the player's queue are skipped on Windows, which will not
  /// replace a file that is open.
  Future<void> mergeLibrary() async {
    if (busy) return;
    final videos = <(Playlist, Entry)>[
      for (final pl in _library.playlists)
        for (final e in pl.entries)
          if (e.filePath != null && isVideoPath(e.filePath)) (pl, e),
    ];
    busy = true;
    done = 0;
    total = videos.length;
    message = null;
    notifyListeners();
    var merged = 0;
    var failed = 0;
    var skipped = 0;
    for (final (_, e) in videos) {
      final path = e.filePath!;
      if (Platform.isWindows && _playback.queue.any((q) => q.filePath == path)) {
        skipped++;
      } else {
        try {
          if (await mergeSidecars(path) > 0) merged++;
        } catch (err) {
          failed++;
          debugPrint('DownloadHQ: merging subtitles into $path: $err');
        }
      }
      done++;
      notifyListeners();
    }
    busy = false;
    message = [
      merged == 0
          ? 'No separate subtitle files found'
          : 'Subtitles put inside $merged ${merged == 1 ? 'video' : 'videos'}',
      if (failed > 0) '$failed could not be changed',
      if (skipped > 0) '$skipped skipped while in the player. Close it and run again',
    ].join('. ');
    notifyListeners();
  }
}
