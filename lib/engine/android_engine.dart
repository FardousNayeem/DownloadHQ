import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'engine.dart';
import 'ytdlp_cli.dart';

/// Android adapter: yt-dlp runs inside youtubedl-android (bundled Python,
/// yt-dlp and ffmpeg). The Kotlin side is a thin `run(args)` bridge; all
/// flag knowledge stays in Dart ([ytdlp_cli.dart]), shared with desktop.
class AndroidEngine implements YtDlpEngine {
  static const _method = MethodChannel('downloadhq/ytdlp');
  static const _events = EventChannel('downloadhq/ytdlp/progress');

  late final Stream<Map> _progress = _events.receiveBroadcastStream().map((e) => (e as Map)).asBroadcastStream();
  var _nextId = 0;
  EnvFlags? _env;

  /// A JS runtime can't be installed on Android at runtime; it has to ship in
  /// the APK as a fake native library (see README). Detect whichever exists.
  Future<EnvFlags> _envFlags() async {
    if (_env != null) return _env!;
    final libDir = await _method.invokeMethod<String>('nativeLibDir');
    String? js;
    if (libDir != null) {
      final deno = p.join(libDir, 'libdeno.so');
      final qjs = p.join(libDir, 'libqjs.so');
      if (await File(deno).exists()) {
        js = 'deno:$deno';
      } else if (await File(qjs).exists()) {
        js = 'quickjs:$qjs';
      }
    }
    return _env = EnvFlags(jsRuntime: js, remoteEjs: js != null);
  }

  Future<_Run> _run(String id, List<String> args) async {
    try {
      final r = await _method.invokeMapMethod<String, dynamic>('run', {'id': id, 'args': args});
      return _Run(r!['code'] as int, r['out'] as String? ?? '', r['err'] as String? ?? '');
    } on PlatformException catch (e) {
      throw EngineException(e.message ?? 'yt-dlp failed to start');
    }
  }

  @override
  Future<EngineStatus> status() async {
    final version = await _method.invokeMethod<String>('version');
    final env = await _envFlags();
    return EngineStatus(
      tools: [
        ToolStatus(name: 'yt-dlp', purpose: 'Bundled in the app', found: version != null, version: version),
        const ToolStatus(name: 'ffmpeg', purpose: 'Bundled in the app', found: true),
        ToolStatus(
          name: 'JS runtime',
          purpose: 'Solves YouTube playback challenges (must ship in the APK)',
          found: env.jsRuntime != null,
          version: env.jsRuntime?.split(':').first,
          required: false,
        ),
      ],
    );
  }

  @override
  Future<RemotePlaylist> fetchPlaylist(String url, {String? cookiesFile}) async {
    final r = await _run('list-${_nextId++}', playlistArgs(url, await _envFlags(), cookiesFile: cookiesFile));
    if (r.code != 0) throw EngineException(summariseError(r.err));
    return parsePlaylistJson(r.out);
  }

  @override
  Future<ProbeResult> probe(String url, {String? cookiesFile}) async {
    final r = await _run('probe-${_nextId++}', probeArgs(url, await _envFlags(), cookiesFile: cookiesFile));
    if (r.code != 0) throw EngineException(summariseError(r.err));
    return parseProbeJson(r.out, url);
  }

  @override
  DownloadTask download(DownloadSpec spec) => _AndroidTask(this, spec, 'dl-${_nextId++}').._start();

  @override
  Future<String> updateYtDlp() async => await _method.invokeMethod<String>('update') ?? 'unknown';
}

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

class _AndroidTask implements DownloadTask {
  _AndroidTask(this.engine, this.spec, this.id);

  final AndroidEngine engine;
  final DownloadSpec spec;
  final String id;
  final _progress = StreamController<DownloadProgress>.broadcast();
  final _result = Completer<DownloadedFile>();
  StreamSubscription? _sub;
  bool _cancelled = false;

  @override
  Stream<DownloadProgress> get progress => _progress.stream;
  @override
  Future<DownloadedFile> get result => _result.future;

  Future<void> _start() async {
    _sub = engine._progress.where((e) => e['id'] == id).listen((e) {
      final line = e['line'] as String?;
      final parsed = line == null ? null : parseProgressLine(line);
      if (parsed != null) {
        _progress.add(parsed);
      } else {
        // Fall back to the library's own percent/eta parsing.
        final pct = (e['progress'] as num?)?.toDouble();
        final eta = (e['eta'] as num?)?.toInt();
        if (pct != null && pct >= 0) {
          _progress.add(
            DownloadProgress(
              fraction: pct / 100,
              eta: eta == null || eta < 0 ? null : Duration(seconds: eta),
            ),
          );
        }
      }
    });
    try {
      await Directory(spec.outputDir).create(recursive: true);
      final r = await engine._run(id, downloadArgs(spec, await engine._envFlags()));
      if (_cancelled) throw DownloadCancelled();
      final path = parseFinalPath(r.out);
      if (r.code != 0 || path == null) throw EngineException(summariseError(r.err));
      final thumb = thumbPathFor(spec);
      _result.complete(DownloadedFile(filePath: path, thumbPath: await File(thumb).exists() ? thumb : null));
    } catch (e) {
      _result.completeError(e);
    } finally {
      await _sub?.cancel();
      await _progress.close();
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    AndroidEngine._method.invokeMethod('cancel', {'id': id});
  }
}
