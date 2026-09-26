import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One JSON document on disk. Writes go to a temp file then rename, so a
/// crash mid-write never leaves a truncated library behind. Writes are
/// serialised: the last one always wins.
class JsonStore {
  JsonStore(this.path);

  final String path;
  Future<void> _queue = Future.value();

  Future<Object?> read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      await quarantine();
      return null;
    }
  }

  /// Moves an unreadable file aside (kept for inspection, never deleted) so
  /// the app starts fresh instead of failing on every launch.
  Future<void> quarantine() async {
    final f = File(path);
    if (await f.exists()) await f.rename('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Never throws: a failed write (disk full, permissions) is logged and the
  /// next write tries again with the full state. Letting the error through
  /// would poison the chain and silently drop every later save.
  Future<void> write(Object? json) {
    final text = const JsonEncoder.withIndent(' ').convert(json);
    return _queue = _queue.then((_) async {
      try {
        await File(path).parent.create(recursive: true);
        final tmp = File('$path.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(path);
      } catch (e) {
        debugPrint('DownloadHQ: could not save $path: $e');
      }
    });
  }
}
