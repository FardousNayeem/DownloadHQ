import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// The three external programs the desktop engine needs.
enum Tool {
  ytdlp('yt-dlp', 'Downloads and lists playlists'),
  ffmpeg('ffmpeg', 'Merges video and audio, converts to m4a'),
  deno('deno', 'Solves YouTube playback challenges');

  const Tool(this.label, this.purpose);

  /// Also the executable's base name.
  final String label;
  final String purpose;
}

/// Finds tools (app bin dir first, then PATH) and installs missing ones from
/// their official GitHub releases into the app bin dir. Desktop only.
class DesktopTools {
  DesktopTools(this.binDir);

  final String binDir;

  bool get _win => Platform.isWindows;
  String _exe(String name) => _win ? '$name.exe' : name;

  String localPath(Tool t) => p.join(binDir, _exe(t.label));

  /// Absolute path of the tool, or null when not installed anywhere.
  Future<String?> resolve(Tool t) async {
    final local = localPath(t);
    if (await File(local).exists()) return local;
    try {
      final r = await Process.run(_win ? 'where' : 'which', [t.label]);
      if (r.exitCode == 0) {
        final first = (r.stdout as String).trim().split(RegExp(r'\r?\n')).first.trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> version(String path, Tool t) async {
    try {
      final r = await Process.run(path, [
        t == Tool.ffmpeg ? '-version' : '--version',
      ]).timeout(const Duration(seconds: 20));
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String).trim().split('\n').first.trim();
      // "ffmpeg version N-1234-g... Copyright" -> "N-1234-g..."; "deno 2.5.1 (...)" -> "2.5.1"
      final m = RegExp(r'(?:version\s+)?(\S*\d\S*)').firstMatch(line.replaceFirst(RegExp(r'^(ffmpeg|deno)\s+'), ''));
      return m?.group(1) ?? line;
    } catch (_) {
      return null;
    }
  }

  /// [onProgress] gets the download fraction, then null while unpacking.
  Future<void> install(Tool t, {void Function(double? fraction)? onProgress}) async {
    await Directory(binDir).create(recursive: true);
    final url = await _downloadUrl(t);
    final tmp = Directory(p.join(binDir, '.tmp-${t.name}'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create();
    try {
      final file = File(p.join(tmp.path, p.basename(Uri.parse(url).path)));
      await _download(url, file, onProgress);
      if (t == Tool.ytdlp) {
        await _moveOver(file, localPath(t));
      } else {
        final out = p.join(tmp.path, 'x');
        onProgress?.call(null);
        // Decompression is CPU heavy; keep the UI isolate free.
        await Isolate.run(() => extractFileToDisk(file.path, out));
        final wanted = t == Tool.ffmpeg ? {_exe('ffmpeg'), _exe('ffprobe')} : {_exe('deno')};
        await for (final f in Directory(out).list(recursive: true)) {
          if (f is File && wanted.contains(p.basename(f.path))) {
            await _moveOver(f, p.join(binDir, p.basename(f.path)));
          }
        }
      }
      if (!_win) {
        for (final name in t == Tool.ffmpeg ? ['ffmpeg', 'ffprobe'] : [p.basename(localPath(t))]) {
          final path = p.join(binDir, name);
          if (await File(path).exists()) await Process.run('chmod', ['+x', path]);
        }
      }
      if (!await File(localPath(t)).exists()) {
        throw Exception('${t.label} was not found in the downloaded archive');
      }
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  /// Rename that replaces an existing target (Windows refuses otherwise).
  Future<void> _moveOver(File f, String to) async {
    final old = File(to);
    if (await old.exists()) await old.delete();
    await f.rename(to);
  }

  Future<String> _downloadUrl(Tool t) async {
    final arm = !_win && await _isArm64();
    const gh = 'https://github.com';
    return switch (t) {
      Tool.ytdlp =>
        _win
            ? '$gh/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
            : '$gh/yt-dlp/yt-dlp/releases/latest/download/${arm ? 'yt-dlp_linux_aarch64' : 'yt-dlp_linux'}',
      Tool.deno =>
        _win
            ? '$gh/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
            : '$gh/denoland/deno/releases/latest/download/deno-${arm ? 'aarch64' : 'x86_64'}-unknown-linux-gnu.zip',
      Tool.ffmpeg =>
        _win
            ? '$gh/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
            : '$gh/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${arm ? 'linuxarm64' : 'linux64'}-gpl.tar.xz',
    };
  }

  Future<bool> _isArm64() async {
    try {
      final r = await Process.run('uname', ['-m']);
      return (r.stdout as String).trim() == 'aarch64';
    } catch (_) {
      return false;
    }
  }

  Future<void> _download(String url, File to, void Function(double?)? onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw Exception('Download failed (HTTP ${res.statusCode})');
      final total = res.contentLength;
      var got = 0;
      final sink = to.openWrite();
      await res
          // A connection that goes quiet mid-file would otherwise hang forever.
          .timeout(const Duration(seconds: 60), onTimeout: (sink) => sink.addError(Exception('Download stalled')))
          .map((chunk) {
            got += chunk.length;
            onProgress?.call(total > 0 ? got / total : null);
            return chunk;
          })
          .pipe(sink);
    } finally {
      client.close();
    }
  }
}
