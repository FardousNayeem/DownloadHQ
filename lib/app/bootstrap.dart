import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/json_store.dart';
import '../data/repositories.dart';
import '../engine/android_engine.dart';
import '../engine/desktop_tools.dart';
import '../engine/engine.dart';
import '../engine/ffmpeg.dart';
import '../engine/process_engine.dart';
import '../services/adblock_service.dart';
import '../services/auto_sync.dart';
import '../services/cookie_service.dart';
import '../services/creator_profile.dart';
import '../services/download_queue.dart';
import '../services/grab_service.dart';
import '../services/library_service.dart';
import '../services/playback_service.dart';
import '../services/settings_service.dart';
import '../services/share_service.dart';
import '../services/subtitle_service.dart';
import '../services/tools_service.dart';

/// The composition root: the one place that knows concrete classes and the
/// platform. Everything else receives its collaborators.
class Services {
  Services._({
    required this.settings,
    required this.library,
    required this.queue,
    required this.tools,
    required this.playback,
    required this.autoSync,
    required this.grab,
    required this.adblock,
    required this.share,
    required this.subtitles,
    required this.creator,
  });

  final SettingsService settings;
  final LibraryService library;
  final DownloadQueue queue;
  final ToolsService tools;
  final PlaybackService playback;
  final AutoSync autoSync;
  final GrabService grab;
  final AdblockService adblock;
  final ShareService share;
  final SubtitleService subtitles;
  final CreatorProfileService creator;

  static Future<Services> create() async {
    final support = await getApplicationSupportDirectory();
    await _migrateFromPlm(support);

    final YtDlpEngine raw;
    DesktopTools? desktop;
    if (Platform.isAndroid) {
      raw = AndroidEngine();
    } else {
      desktop = DesktopTools(p.join(support.path, 'bin'));
      raw = ProcessEngine(desktop);
    }
    final settingsRepo = SettingsRepository(
      JsonStore(p.join(support.path, 'settings.json')),
      await _defaultDownloadDir(),
    );
    final settings = SettingsService(settingsRepo, await settingsRepo.load());
    // Session files live in the app's own cache, never next to the media.
    final cookies = CookieService(
      p.join((await getApplicationCacheDirectory()).path, 'session'),
      userFile: () => settings.value.cookiesFile,
    );
    await cookies.sweep();
    final YtDlpEngine engine = SignInFallbackEngine(raw, cookies);
    final library = LibraryService(JsonLibraryRepository(JsonStore(p.join(support.path, 'library.json'))), engine);
    await library.load();

    final playback = PlaybackService(state: JsonStore(p.join(support.path, 'playback.json')));
    final subtitles = SubtitleService(
      Platform.isAndroid ? AndroidFfmpeg() : DesktopFfmpeg(desktop!),
      library,
      playback,
    );
    final queue = DownloadQueue(engine, library, settings, cookies: cookies, subtitles: subtitles);
    final adblock = AdblockService(support.path);
    await adblock.load();
    return Services._(
      settings: settings,
      library: library,
      queue: queue,
      grab: GrabService(engine, library, queue),
      tools: ToolsService(raw, desktop),
      playback: playback,
      subtitles: subtitles,
      creator: CreatorProfileService(),
      autoSync: AutoSync(library, settings),
      adblock: adblock,
      share: ShareService(),
    );
  }

  /// Android: app-specific external storage (no permission needed, removed
  /// with the app). Desktop: a visible folder in the user's Music directory.
  static Future<String> _defaultDownloadDir() async {
    final String base;
    if (Platform.isAndroid) {
      base = ((await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()).path;
    } else {
      final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      base = home != null ? p.join(home, 'Music') : (await getApplicationDocumentsDirectory()).path;
    }
    // The app was called PLM; a folder it already filled stays in use.
    final old = p.join(base, 'PLM');
    if (!Platform.isAndroid && await Directory(old).exists()) return old;
    return p.join(base, 'DownloadHQ');
  }

  /// The app used to be PLM (`com.nayeem.plm`). On desktop its data lives
  /// next to the new support directory, so the library, settings and
  /// installed tools are copied over once. The old folder is left alone.
  /// Android keeps each app id in its own sandbox; nothing to reach there.
  static Future<void> _migrateFromPlm(Directory support) async {
    if (Platform.isAndroid) return;
    if (await File(p.join(support.path, 'library.json')).exists()) return;
    final candidates = [
      p.join(support.parent.path, 'com.nayeem.plm'), // Linux: ~/.local/share/<app id>
      p.join(support.parent.path, 'plm'), // Linux, when no app id was registered
      p.join(support.parent.parent.path, 'com.nayeem', 'PLM'), // Windows: %APPDATA%\<company>\<product>
    ];
    for (final old in candidates) {
      if (!await File(p.join(old, 'library.json')).exists()) continue;
      try {
        await for (final e in Directory(old).list(recursive: true, followLinks: false)) {
          if (e is! File || e.path.contains('.corrupt-') || e.path.endsWith('.tmp')) continue;
          final to = File(p.join(support.path, p.relative(e.path, from: old)));
          await to.parent.create(recursive: true);
          await e.copy(to.path);
          if (!Platform.isWindows && p.split(p.relative(e.path, from: old)).first == 'bin') {
            await Process.run('chmod', ['+x', to.path]);
          }
        }
      } catch (e) {
        debugPrint('DownloadHQ: could not copy data from $old: $e');
      }
      return;
    }
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final Services services;

  static Services of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
