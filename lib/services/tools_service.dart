import 'package:flutter/foundation.dart';

import '../engine/desktop_tools.dart';
import '../engine/engine.dart';

/// Tool health for the settings screen: status, install (desktop), update.
/// Installs run one at a time from a queue, so several can be requested at
/// once without two large downloads fighting for bandwidth.
class ToolsService extends ChangeNotifier {
  ToolsService(this._engine, this._desktop);

  final YtDlpEngine _engine;

  /// Null on Android, where tools ship inside the APK.
  final DesktopTools? _desktop;

  EngineStatus? status;
  String? message;

  /// Tool being worked on right now, and its download fraction (null while
  /// unpacking or when size is unknown).
  String? busyTool;
  double? busyProgress;
  bool _sawBytes = false;
  final List<String> _waiting = [];

  /// Human label for what the busy tool is doing.
  String get busyStage => busyProgress != null ? 'Downloading' : (_sawBytes ? 'Unpacking' : 'Starting');

  bool get canInstall => _desktop != null;
  bool get ready => status?.ready ?? false;
  bool get busy => busyTool != null;
  bool isWaiting(String tool) => _waiting.contains(tool);
  bool isQueued(String tool) => tool == busyTool || isWaiting(tool);

  List<String> get missing => [
    for (final t in status?.tools ?? const <ToolStatus>[])
      if (!t.found && t.installable) t.name,
  ];

  Future<void> refresh() async {
    try {
      status = await _engine.status();
    } catch (e) {
      message = e.toString();
    }
    notifyListeners();
  }

  void install(String toolName) => _enqueue([toolName]);
  void installMissing() => _enqueue(missing);

  void _enqueue(List<String> tools) {
    for (final t in tools) {
      if (t != busyTool && !_waiting.contains(t)) _waiting.add(t);
    }
    notifyListeners();
    if (!busy) _drain();
  }

  Future<void> _drain() async {
    final failures = <String>[];
    final done = <String>[];
    while (_waiting.isNotEmpty) {
      final name = _waiting.removeAt(0);
      final tool = Tool.values.firstWhere((t) => t.label == name);
      try {
        await _run(
          name,
          () => _desktop!.install(
            tool,
            onProgress: (f) {
              busyProgress = f;
              if (f != null) _sawBytes = true;
              notifyListeners();
            },
          ),
        );
        done.add(name);
      } catch (e) {
        failures.add('$name: $e');
      }
      await refresh(); // show each tool as found as soon as it lands
    }
    message = failures.isNotEmpty
        ? 'Failed. ${failures.join('. ')}'
        : done.isEmpty
        ? null
        : '${done.join(', ')} installed';
    await refresh();
  }

  Future<void> updateYtDlp() async {
    if (busy) return;
    try {
      String? v;
      await _run('yt-dlp', () async => v = await _engine.updateYtDlp());
      message = 'yt-dlp is now $v';
    } catch (e) {
      message = 'Update failed: $e';
    }
    await refresh();
  }

  Future<void> _run(String tool, Future<void> Function() work) async {
    busyTool = tool;
    busyProgress = null;
    _sawBytes = false;
    message = null;
    notifyListeners();
    try {
      await work();
    } finally {
      busyTool = null;
      busyProgress = null;
      notifyListeners();
    }
  }
}
