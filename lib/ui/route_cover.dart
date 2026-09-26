import 'package:flutter/widgets.dart';

/// Counts routes pushed above a navigator's first route (pages, dialogs,
/// bottom sheets), so a native view underneath can get out of their way.
class RouteCoverTracker extends NavigatorObserver with ChangeNotifier {
  int _depth = 0;

  bool get covered => _depth > 0;

  void _set(int d) {
    final was = covered;
    _depth = d < 0 ? 0 : d;
    if (was != covered) notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    if (previousRoute != null) _set(_depth + 1);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (previousRoute != null) _set(_depth - 1);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (previousRoute != null) _set(_depth - 1);
  }
}

/// Routes above the app shell (full player, top-level dialogs).
final rootRouteCover = RouteCoverTracker();

/// The app's top navigator, above the per-tab ones.
final rootNavigator = GlobalKey<NavigatorState>();
