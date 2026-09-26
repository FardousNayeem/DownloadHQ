import 'dart:async';

import 'package:flutter/widgets.dart';

import 'library_service.dart';
import 'settings_service.dart';

/// Decides when to look for new playlist entries: on launch, on returning to
/// the app after the interval passed, and on a timer while it stays open.
/// No background service: an offline player has no need to wake the phone.
class AutoSync with WidgetsBindingObserver {
  AutoSync(this._library, this._settings);

  final LibraryService _library;
  final SettingsService _settings;
  Timer? _timer;
  DateTime? _lastRun;
  Duration? _scheduled;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _settings.addListener(_reschedule);
    _run();
    _reschedule();
  }

  Duration? get _interval {
    final h = _settings.value.checkEveryHours;
    return h <= 0 ? null : Duration(hours: h);
  }

  /// Settings change for many reasons (theme, last grab mode); restarting
  /// the timer on each would keep pushing the next check away.
  void _reschedule() {
    final i = _interval;
    if (_timer != null && i == _scheduled) return;
    _timer?.cancel();
    _scheduled = i;
    _timer = i == null ? null : Timer.periodic(i, (_) => _run());
  }

  void _run() {
    _lastRun = DateTime.now();
    _library.verifyFiles().then((_) => _library.syncAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final i = _interval;
    if (state != AppLifecycleState.resumed || i == null || _lastRun == null) return;
    if (DateTime.now().difference(_lastRun!) >= i) _run();
  }

  void dispose() {
    _timer?.cancel();
    _settings.removeListener(_reschedule);
    WidgetsBinding.instance.removeObserver(this);
  }
}
