import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'desktop_tools.dart';
import 'engine.dart';
import 'ytdlp_cli.dart';

/// Desktop adapter (Linux, Windows): runs the yt-dlp binary as a child process.
class ProcessEngine implements YtDlpEngine {
  ProcessEngine(this.tools);

  final DesktopTools tools;

  // Force UTF-8 so non-ASCII titles and paths survive the Windows console.
  static const _env = {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'};

  /// A stray byte in a title must not crash the whole read.
  static const _utf8 = Utf8Codec(allowMalformed: true);

  /// Listing a page is quick; a run this long is stuck (network stall).
  static const _listTimeout = Duration(minutes: 3);

  /// Runs yt-dlp to completion and returns stdout, or throws with its error.
  Future<String> _capture(List<String> Function(EnvFlags) args) async {
    final (bin, env) = await _prepare();
    final proc = await Process.start(bin, args(env), environment: _env);
    final out = proc.stdout.transform(_utf8.decoder).join();
    final err = proc.stderr.transform(_utf8.decoder).join();
    final code = await proc.exitCode.timeout(
      _listTimeout,
      onTimeout: () {
        killTree(proc);
        throw EngineException('yt-dlp took too long to answer. Check your connection and try again.');
      },
    );
    if (code != 0) throw EngineException(summariseError(await err));
    return out;
  }

  Future<(String, EnvFlags)> _prepare() async {
    final ytdlp = await tools.resolve(Tool.ytdlp);
    if (ytdlp == null) throw EngineException('yt-dlp is not installed. Open Settings to install it.');
    final ffmpeg = await tools.resolve(Tool.ffmpeg);
    final deno = await tools.resolve(Tool.deno);
    return (ytdlp, EnvFlags(ffmpegPath: ffmpeg, jsRuntime: deno == null ? null : 'deno:$deno'));
  }

  @override
  Future<EngineStatus> status() async {
    final out = <ToolStatus>[];
    for (final t in Tool.values) {
      final path = await tools.resolve(t);
      out.add(
        ToolStatus(
          name: t.label,
          purpose: t.purpose,
          found: path != null,
          path: path,
          version: path == null ? null : await tools.version(path, t),
          installable: true,
        ),
      );
    }
    return EngineStatus(tools: out);
  }

  @override
  Future<RemotePlaylist> fetchPlaylist(String url) async =>
      parsePlaylistJson(await _capture((env) => playlistArgs(url, env)));

  @override
  Future<ProbeResult> probe(String url) async => parseProbeJson(await _capture((env) => probeArgs(url, env)), url);

  @override
  DownloadTask download(DownloadSpec spec) => _ProcessTask(this, spec).._start();

  @override
  Future<String> updateYtDlp() async {
    // Always install our own copy: a system yt-dlp from a package manager
    // can't self-update and usually lags behind YouTube changes.
    await tools.install(Tool.ytdlp);
    return await tools.version(tools.localPath(Tool.ytdlp), Tool.ytdlp) ?? 'unknown';
  }
}

class _ProcessTask implements DownloadTask {
  _ProcessTask(this.engine, this.spec);

  final ProcessEngine engine;
  final DownloadSpec spec;
  final _progress = StreamController<DownloadProgress>.broadcast();
  final _result = Completer<DownloadedFile>();
  Process? _proc;
  bool _cancelled = false;

  @override
  Stream<DownloadProgress> get progress => _progress.stream;
  @override
  Future<DownloadedFile> get result => _result.future;

  Future<void> _start() async {
    try {
      final (bin, env) = await engine._prepare();
      if (_cancelled) throw DownloadCancelled();
      final proc = await Process.start(bin, downloadArgs(spec, env), environment: ProcessEngine._env);
      _proc = proc;
      // cancel() may have run while the process was starting, when there was
      // nothing to kill yet.
      if (_cancelled) killTree(proc);
      final out = StringBuffer();
      final err = StringBuffer();
      final outDone = proc.stdout.transform(ProcessEngine._utf8.decoder).transform(const LineSplitter()).forEach((l) {
        out.writeln(l);
        final pr = parseProgressLine(l);
        if (pr != null) _progress.add(pr);
      });
      final errDone = proc.stderr.transform(ProcessEngine._utf8.decoder).forEach(err.write);
      final code = await proc.exitCode;
      await Future.wait([outDone, errDone]);
      if (_cancelled) throw DownloadCancelled();
      final path = parseFinalPath(out.toString());
      if (code != 0 || path == null) throw EngineException(summariseError(err.toString()));
      final thumb = thumbPathFor(spec);
      _result.complete(DownloadedFile(filePath: path, thumbPath: await File(thumb).exists() ? thumb : null));
    } catch (e) {
      _result.completeError(e);
    } finally {
      await _progress.close();
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    // yt-dlp leaves a .part file; it resumes from it on retry, which is fine.
    final p = _proc;
    if (p != null) killTree(p);
  }
}

/// Stops yt-dlp and whatever it started. On Windows killing the parent leaves
/// its ffmpeg child running, so the whole tree goes.
void killTree(Process p) {
  if (Platform.isWindows) {
    Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']).ignore();
  } else {
    p.kill();
  }
}
