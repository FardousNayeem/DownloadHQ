import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_tools.dart';
import 'engine.dart';

/// Runs ffmpeg for work yt-dlp does not do: putting leftover subtitle files
/// inside videos, burning subtitles into the picture.
abstract interface class FfmpegRunner {
  /// Runs to completion. Throws [EngineException] with ffmpeg's last error
  /// line on failure. [onLine] gets stdout lines (`-progress pipe:1`).
  Future<void> run(List<String> args, {String? workingDir, void Function(String line)? onLine});

  /// Whether burning in is possible here (needs libass and libx264).
  bool get canBurn;
}

/// Desktop: the ffmpeg binary Settings installs (or one on PATH).
class DesktopFfmpeg implements FfmpegRunner {
  DesktopFfmpeg(this._tools);
  final DesktopTools _tools;

  @override
  bool get canBurn => true;

  @override
  Future<void> run(List<String> args, {String? workingDir, void Function(String line)? onLine}) async {
    final bin = await _tools.resolve(Tool.ffmpeg);
    if (bin == null) throw EngineException('ffmpeg is not installed. Open Settings to install it.');
    final proc = await Process.start(bin, args, workingDirectory: workingDir);
    final err = StringBuffer();
    final outDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((l) => onLine?.call(l));
    final errDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write);
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    if (code != 0) throw EngineException(lastFfmpegError(err.toString()));
  }
}

/// Android: the ffmpeg that ships inside youtubedl-android, started by
/// MainActivity with the library path it needs. No progress lines, and
/// that build is not relied on for burning in.
class AndroidFfmpeg implements FfmpegRunner {
  static const _method = MethodChannel('downloadhq/ytdlp');

  @override
  bool get canBurn => false;

  @override
  Future<void> run(List<String> args, {String? workingDir, void Function(String line)? onLine}) async {
    try {
      final r = await _method.invokeMapMethod<String, dynamic>('ffmpeg', {'args': args, 'cwd': workingDir});
      if ((r?['code'] as int? ?? 1) != 0) throw EngineException(lastFfmpegError(r?['err'] as String? ?? ''));
    } on PlatformException catch (e) {
      throw EngineException(e.message ?? 'ffmpeg failed to start');
    }
  }
}

/// ffmpeg prints its whole banner and stream list to stderr; the last
/// non-empty line is the one that says what went wrong.
String lastFfmpegError(String stderr) {
  final lines = const LineSplitter().convert(stderr).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  return lines.isEmpty ? 'ffmpeg failed' : lines.last;
}
