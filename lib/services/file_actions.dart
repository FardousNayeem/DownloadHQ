import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Hands a saved file to the rest of the system: the file manager, another
/// player, the share sheet. Desktop shells out; Android goes through
/// MainActivity (FileProvider + intents).
class FileActions {
  static const _android = MethodChannel('downloadhq/files');

  /// Android keeps downloads in app storage no file manager can browse, so
  /// "show in folder" is a desktop action; Android gets "open with" instead.
  static bool get canReveal => !Platform.isAndroid;
  static bool get canShare => Platform.isAndroid;

  /// Opens the file manager with [path] selected (or its folder, when the
  /// file manager cannot select).
  static Future<void> reveal(String path) async {
    if (Platform.isWindows) {
      // explorer.exe exits 1 even when it worked; nothing to check.
      await Process.run('explorer.exe', ['/select,', path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
      return;
    }
    // Linux: the FileManager1 D-Bus interface (Nautilus, Dolphin, Nemo,
    // Caja, Thunar) highlights the file. Fall back to opening the folder.
    try {
      final r = await Process.run('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:${Uri.file(path)}',
        'string:',
      ]);
      if (r.exitCode == 0) return;
    } catch (_) {}
    await _xdgOpen(p.dirname(path));
  }

  /// Opens [path] in the system's default app for its type (VLC, Films...).
  static Future<void> openExternally(String path) async {
    if (Platform.isAndroid) {
      await _android.invokeMethod('open', {'path': path});
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path], runInShell: false);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await _xdgOpen(path);
    }
  }

  static Future<void> share(String path, {String? title}) =>
      _android.invokeMethod('share', {'path': path, 'title': title});

  static Future<void> _xdgOpen(String target) async {
    final r = await Process.run('xdg-open', [target]);
    if (r.exitCode != 0) throw FileSystemException('No app to open this', target);
  }
}
