import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Links shared to DownloadHQ from other apps (Android "Share" sheet, e.g.
/// from the YouTube app). Desktop has no share target; the stream stays
/// empty there.
class ShareService {
  ShareService() {
    if (!Platform.isAndroid) return;
    _method.setMethodCallHandler((call) async {
      if (call.method == 'shared') _receive(call.arguments as String?);
    });
    _method.invokeMethod<String>('initial').then(_receive, onError: (Object e) => debugPrint('share: $e'));
  }

  static const _method = MethodChannel('downloadhq/share');
  final _links = StreamController<String>.broadcast();
  String? _pending;

  /// Links shared while the app runs.
  Stream<String> get links => _links.stream;

  /// A link that arrived before anyone listened (the app was launched by a
  /// share). Returned once.
  String? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  void _receive(String? text) {
    final url = linkIn(text);
    if (url == null) return;
    if (_links.hasListener) {
      _links.add(url);
    } else {
      _pending = url;
    }
  }
}

/// Apps share "Title https://youtu.be/x" or just the link; take the link.
@visibleForTesting
String? linkIn(String? text) {
  if (text == null) return null;
  final m = RegExp(r'https?://\S+').firstMatch(text);
  return m?.group(0)?.replaceFirst(RegExp(r'[)\].,;!?]+$'), '');
}
