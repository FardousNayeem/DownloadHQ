import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/json_store.dart';
import '../domain/adblock.dart';

/// One subscribable filter list.
class FilterListInfo {
  const FilterListInfo(this.id, this.name, this.url, {this.defaultOn = true});
  final String id;
  final String name;
  final String url;
  final bool defaultOn;
}

/// The lists uBlock Origin enables out of the box, plus two optional ones
/// that matter in a phone browser.
const filterLists = [
  FilterListInfo('ubo-filters', 'uBlock filters: Ads', 'https://ublockorigin.github.io/uAssets/filters/filters.txt'),
  FilterListInfo(
    'ubo-privacy',
    'uBlock filters: Privacy',
    'https://ublockorigin.github.io/uAssets/filters/privacy.txt',
  ),
  FilterListInfo(
    'ubo-quick',
    'uBlock filters: Quick fixes',
    'https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt',
  ),
  FilterListInfo('easylist', 'EasyList', 'https://easylist.to/easylist/easylist.txt'),
  FilterListInfo('easyprivacy', 'EasyPrivacy', 'https://easylist.to/easylist/easyprivacy.txt'),
  FilterListInfo(
    'pgl',
    "Peter Lowe's Ad and tracking server list",
    'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext',
  ),
  FilterListInfo(
    'adguard-mobile',
    'AdGuard Mobile Ads',
    'https://filters.adtidy.org/extension/ublock/filters/11.txt',
    defaultOn: false,
  ),
  FilterListInfo(
    'easylist-cookies',
    'EasyList Cookie notices',
    'https://ublockorigin.github.io/uAssets/thirdparties/easylist-cookies.txt',
    defaultOn: false,
  ),
];

/// Owns the ad blocker: which lists are on, keeping them fresh, the merged
/// rules, per-site pauses, and the counts shown in the browser.
class AdblockService extends ChangeNotifier {
  AdblockService(this._dir) : _store = JsonStore(p.join(_dir, 'adblock.json'));

  final String _dir;
  final JsonStore _store;

  /// Lists are refreshed this often, the same cadence uBlock uses.
  static const maxAge = Duration(days: 4);

  /// Hosts embedded in the page script (see [compactHosts]).
  static const pageHostLimit = 12000;
  static const pageThirdPartyLimit = 5000;

  bool _enabled = true;
  final Set<String> _paused = {};
  final Set<String> _lists = {
    for (final l in filterLists)
      if (l.defaultOn) l.id,
  };
  final Map<String, DateTime> _updated = {};
  int _totalBlocked = 0;

  FilterSet _filters = FilterSet(hosts: {...builtinAdHosts});
  List<String> _pageHosts = compactHosts(builtinAdHosts, pageHostLimit);
  List<String> _pageHosts3p = const [];
  final Map<String, String> _scriptCache = {};

  bool updating = false;
  String? message;

  int _pageNav = 0;
  int _pageScript = 0;

  /// Items blocked on the page open in the browser.
  int get pageBlocked => _pageNav + _pageScript;

  bool get enabled => _enabled;
  Set<String> get pausedHosts => Set.unmodifiable(_paused);
  bool isListOn(String id) => _lists.contains(id);
  int get enabledListCount => _lists.length;
  DateTime? listUpdated(String id) => _updated[id];
  int get totalBlocked => _totalBlocked;
  int get networkRuleCount => _filters.networkRuleCount;
  int get siteRuleCount => _filters.siteRuleCount;
  DateTime? get lastUpdated => _updated.values.fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

  String _listPath(String id) => p.join(_dir, 'filters', '$id.txt');

  Future<void> load() async {
    final j = await _store.read();
    if (j is Map) {
      try {
        _enabled = j['enabled'] as bool? ?? true;
        _paused.addAll([for (final h in j['paused'] as List? ?? const []) h as String]);
        if (j['lists'] is List) {
          _lists
            ..clear()
            ..addAll([for (final id in j['lists'] as List) id as String]);
        }
        final up = (j['updated'] as Map?)?.cast<String, dynamic>() ?? const {};
        for (final e in up.entries) {
          final t = DateTime.tryParse(e.value as String? ?? '');
          if (t != null) _updated[e.key] = t;
        }
        _totalBlocked = j['totalBlocked'] as int? ?? 0;
      } catch (_) {
        await _store.quarantine();
      }
    }
    await _rebuild();
  }

  Future<void> _save() => _store.write({
    'enabled': _enabled,
    'paused': _paused.toList(),
    'lists': _lists.toList(),
    'updated': {for (final e in _updated.entries) e.key: e.value.toIso8601String()},
    'totalBlocked': _totalBlocked,
  });

  /// Re-reads the enabled lists from disk. Parsing 100,000+ lines is kept
  /// off the UI isolate.
  Future<void> _rebuild() async {
    // Ad lists before privacy lists: when the page script's host budget
    // runs out, the hosts that serve visible ads are the ones kept.
    const priority = [
      'pgl',
      'ubo-filters',
      'ubo-quick',
      'adguard-mobile',
      'easylist',
      'ubo-privacy',
      'easylist-cookies',
      'easyprivacy',
    ];
    final ids = _lists.toList()..sort((a, b) => priority.indexOf(a).compareTo(priority.indexOf(b)));
    final paths = [for (final id in ids) _listPath(id)];
    final built = await Isolate.run(() {
      final all = FilterSet(hosts: {...builtinAdHosts});
      for (final path in paths) {
        final f = File(path);
        if (f.existsSync()) all.addAll(parseFilterList(f.readAsStringSync()));
      }
      all.hosts.removeAll(all.allowHosts);
      // Built-in hosts come first in the set: they are the ones seen most.
      final ordered = all.hosts;
      return (all, compactHosts(ordered, pageHostLimit), compactHosts(all.thirdPartyHosts, pageThirdPartyLimit));
    });
    _filters = built.$1;
    _pageHosts = built.$2;
    _pageHosts3p = built.$3;
    _scriptCache.clear();
    notifyListeners();
  }

  /// Downloads lists that are missing or older than [maxAge] (all enabled
  /// ones when [force]). Never throws; failures land in [message].
  Future<void> updateLists({bool force = false}) async {
    if (updating) return;
    final due = [
      for (final l in filterLists)
        if (_lists.contains(l.id) &&
            (force ||
                !File(_listPath(l.id)).existsSync() ||
                DateTime.now().difference(_updated[l.id] ?? DateTime(2000)) > maxAge))
          l,
    ];
    if (due.isEmpty) return;
    updating = true;
    message = null;
    notifyListeners();
    final failed = <String>[];
    for (final l in due) {
      try {
        final text = await _fetch(l.url);
        // A captive portal or error page is not a filter list.
        final rules = await Isolate.run(() {
          final f = parseFilterList(text);
          return f.networkRuleCount + f.siteRuleCount;
        });
        if (rules == 0) throw const FormatException('no rules');
        final f = File(_listPath(l.id));
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
        _updated[l.id] = DateTime.now();
      } catch (e) {
        failed.add(l.name);
      }
    }
    await _save();
    await _rebuild();
    updating = false;
    message = failed.isEmpty ? null : 'Could not update ${failed.join(', ')}. Check your connection.';
    notifyListeners();
  }

  Future<String> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return await res.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(minutes: 2));
    } finally {
      client.close();
    }
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    _scriptCache.clear();
    notifyListeners();
    await _save();
  }

  Future<void> setListOn(String id, bool on) async {
    on ? _lists.add(id) : _lists.remove(id);
    notifyListeners();
    await _save();
    if (on && !File(_listPath(id)).existsSync()) {
      await updateLists();
    } else {
      await _rebuild();
    }
  }

  /// Pauses or resumes blocking on [host] and every subdomain of it.
  Future<void> setPaused(String host, bool paused) async {
    final site = siteOf(host);
    paused ? _paused.add(site) : _paused.removeWhere((h) => h == site || hostListed(host, {h}));
    _scriptCache.clear();
    notifyListeners();
    await _save();
  }

  bool isPaused(String host) => host.isNotEmpty && hostListed(host, _paused);

  /// Browser navigation check (main frame, pop-ups, frames).
  bool shouldBlock(String url, {required bool isMainFrame, String? pageUrl}) {
    if (!_enabled) return false;
    return shouldBlockNavigation(url, _filters, isMainFrame: isMainFrame, pageUrl: pageUrl, pausedHosts: _paused);
  }

  /// The document-start script for pages on [host], or null when blocking
  /// is off. Cached per host until the rules change.
  String? scriptFor(String host) {
    if (!_enabled) return null;
    final h = host.toLowerCase();
    return _scriptCache[h] ??= () {
      final r = _filters.rulesFor(h);
      return buildAdblockScript(
        siteHost: h,
        hosts: _pageHosts,
        thirdPartyHosts: _pageHosts3p,
        allowHosts: _filters.allowHosts,
        hide: r.hide,
        scriptlets: r.scriptlets,
        pausedHosts: _paused,
      );
    }();
  }

  /// A navigation the browser refused.
  void countNavigationBlocked() {
    _pageNav++;
    _totalBlocked++;
    _saveCountsSoon();
    notifyListeners();
  }

  /// The page script's running count for the current page.
  void reportPageCount(int n) {
    if (n <= _pageScript) return;
    _totalBlocked += n - _pageScript;
    _pageScript = n;
    _saveCountsSoon();
    notifyListeners();
  }

  /// A new document: the page script starts counting from zero. Blocked
  /// pop-ups and redirects stay counted against the page the user is on.
  void newPage({bool keepNavigations = false}) {
    if (_pageScript == 0 && (keepNavigations || _pageNav == 0)) return;
    _pageScript = 0;
    if (!keepNavigations) _pageNav = 0;
    notifyListeners();
  }

  Timer? _countSave;
  void _saveCountsSoon() {
    if (_countSave?.isActive ?? false) return;
    _countSave = Timer(const Duration(seconds: 5), _save);
  }

  @override
  void dispose() {
    _countSave?.cancel();
    super.dispose();
  }
}
