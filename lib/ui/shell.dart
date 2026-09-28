import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/bootstrap.dart';
import 'route_cover.dart';
import 'screens/browse_screen.dart';
import 'screens/creator_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/mini_player.dart';

/// Tabs with one nested navigator each, so the mini player and navigation
/// stay visible while browsing into a playlist. Bottom bar on phones, rail on
/// wide windows. The app opens on the browser.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  static const _browseTab = 0;
  static const _settingsTab = 3;
  int _tab = _browseTab;
  final _keys = List.generate(5, (_) => GlobalKey<NavigatorState>());

  /// Whether the browser page can be seen right now: its tab is selected and
  /// no sheet, dialog or page sits on top of it.
  final _browseVisible = ValueNotifier(true);
  final _browseCover = RouteCoverTracker();
  StreamSubscription<String>? _shareSub;

  @override
  void initState() {
    super.initState();
    rootRouteCover.addListener(_updateBrowseVisible);
    _browseCover.addListener(_updateBrowseVisible);
    // A link shared from another app opens in the browser.
    _shareSub = AppScope.of(context).share.links.listen((_) {
      rootNavigator.currentState?.popUntil((r) => r.isFirst);
      _keys[_browseTab].currentState?.popUntil((r) => r.isFirst);
      if (_tab != _browseTab) _select(_browseTab);
    });
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    rootRouteCover.removeListener(_updateBrowseVisible);
    _browseCover.removeListener(_updateBrowseVisible);
    _browseVisible.dispose();
    super.dispose();
  }

  void _updateBrowseVisible() =>
      _browseVisible.value = _tab == _browseTab && !rootRouteCover.covered && !_browseCover.covered;

  void _select(int i) {
    if (i == _tab) {
      // Tapping the current tab returns to its root.
      _keys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
      _updateBrowseVisible();
    }
  }

  Widget _tabNavigator(int i, Widget root, {List<NavigatorObserver> observers = const []}) => Navigator(
    key: _keys[i],
    observers: observers,
    onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => root),
  );

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final pages = IndexedStack(
      index: _tab,
      children: [
        _tabNavigator(_browseTab, BrowseScreen(visible: _browseVisible), observers: [_browseCover]),
        _tabNavigator(1, LibraryScreen(onOpenSettings: () => _select(_settingsTab))),
        _tabNavigator(2, const DownloadsScreen()),
        _tabNavigator(_settingsTab, const SettingsScreen()),
        _tabNavigator(4, CreatorScreen(profiles: s.creator)),
      ],
    );

    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.queue]),
      builder: (context, _) {
        final newCount = s.library.totalNew;
        final active = s.queue.activeCount;
        Widget badge(Widget icon, int n) => n == 0 ? icon : Badge(label: Text('$n'), child: icon);
        final dests = [
          (const Icon(PhosphorIconsRegular.compass), const Icon(PhosphorIconsFill.compass), 'Browse'),
          (
            badge(const Icon(PhosphorIconsRegular.playlist), newCount),
            badge(const Icon(PhosphorIconsFill.playlist), newCount),
            'Library',
          ),
          (
            badge(const Icon(PhosphorIconsRegular.downloadSimple), active),
            badge(const Icon(PhosphorIconsBold.downloadSimple), active),
            'Downloads',
          ),
          (const Icon(PhosphorIconsRegular.gear), const Icon(PhosphorIconsFill.gear), 'Settings'),
          (const Icon(PhosphorIconsRegular.userCircle), const Icon(PhosphorIconsFill.userCircle), 'Creator'),
        ];

        return NavigatorPopHandler(
          onPopWithResult: (_) => _keys[_tab].currentState?.maybePop(),
          child: Scaffold(
            body: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _tab,
                        onDestinationSelected: _select,
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final d in dests)
                            NavigationRailDestination(icon: d.$1, selectedIcon: d.$2, label: Text(d.$3)),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: pages),
                            const SafeArea(top: false, child: MiniPlayer()),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: pages),
                      const MiniPlayer(),
                    ],
                  ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _select,
                    destinations: [
                      for (final d in dests) NavigationDestination(icon: d.$1, selectedIcon: d.$2, label: d.$3),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
