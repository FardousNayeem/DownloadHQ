import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app/bootstrap.dart';
import 'app/theme.dart';
import 'ui/route_cover.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final services = await Services.create();
  runApp(AppScope(services: services, child: const DownloadHqApp()));
  services.autoSync.start();
  _startTools(services);
  // Fresh filter lists on first run and every few days after.
  services.adblock.updateLists();
}

class DownloadHqApp extends StatelessWidget {
  const DownloadHqApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'DownloadHQ',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: settings.value.themeMode,
        navigatorKey: rootNavigator,
        navigatorObservers: [rootRouteCover],
        home: const Shell(),
      ),
    );
  }
}

/// Tool status for Settings, then a daily yt-dlp update when that is on.
Future<void> _startTools(Services s) async {
  await s.tools.refresh();
  final settings = s.settings;
  if (!settings.value.autoUpdateYtDlp) return;
  if (await s.tools.autoUpdateIfDue(last: settings.value.lastYtDlpUpdate)) {
    settings.update((v) => v.copyWith(lastYtDlpUpdate: DateTime.now()));
  }
}
