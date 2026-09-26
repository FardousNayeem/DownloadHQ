/// Pure ad blocking engine, modelled on uBlock Origin and fed by the same
/// filter lists it ships with (uBlock filters, EasyList, EasyPrivacy, Peter
/// Lowe's list). No IO: the service owns downloads and storage, the browser
/// owns the web view.
///
/// None of the platform web views DownloadHQ runs in (Android WebView,
/// WebKitGTK, WebView2) can load browser extensions or expose a hook for
/// sub-resource requests, so uBlock itself can't run. Its filters are
/// enforced in three layers instead:
/// 1. Navigations (pages, pop-unders, frames where the platform reports
///    them) to blocked hosts are refused by the browser's navigation
///    delegate. This layer sees the full host list.
/// 2. A document-start script, injected into every frame of every site,
///    stops the page from requesting blocked hosts (fetch, XHR, beacons,
///    script/iframe/img sources, window.open).
/// 3. The same script applies the site's cosmetic rules and uBlock
///    scriptlets, and prunes ads out of YouTube's player responses.
library;

import 'dart:convert';

/// Ad and tracking hosts blocked before any list has been downloaded. A
/// host matches itself and every subdomain.
const builtinAdHosts = <String>{
  // Google ad serving and measurement
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'googletagservices.com',
  'adservice.google.com', 'googletagmanager.com', 'google-analytics.com', 'imasdk.googleapis.com',
  'fundingchoicesmessages.google.com',
  // Exchanges, SSPs, DSPs
  'adnxs.com', 'adsrvr.org', 'amazon-adsystem.com', 'criteo.com', 'criteo.net', 'pubmatic.com',
  'rubiconproject.com', 'openx.net', 'casalemedia.com', 'indexww.com', 'smartadserver.com',
  'yieldmo.com', 'sharethrough.com', 'triplelift.com', '3lift.com', 'teads.tv', 'spotxchange.com',
  'spotx.tv', 'adform.net', 'bidswitch.net', 'contextweb.com', 'gumgum.com', 'media.net',
  'onetag-sys.com', 'sovrn.com', 'lijit.com', 'adsafeprotected.com', 'moatads.com',
  'doubleverify.com', 'serving-sys.com', 'flashtalking.com', 'adroll.com', 'quantserve.com',
  'scorecardresearch.com', 'zedo.com', 'advertising.com', 'adcash.com', 'adsterra.com',
  'propellerads.com', 'popads.net', 'popcash.net', 'exoclick.com', 'exosrv.com', 'juicyads.com',
  'trafficjunky.net', 'hilltopads.net', 'clickadu.com', 'onclickads.net', 'mgid.com',
  'revcontent.com', 'taboola.com', 'outbrain.com', 'infolinks.com', 'a-ads.com', 'coinzilla.com',
  'bidvertiser.com', 'adskeeper.com', 'unityads.unity3d.com', 'applovin.com', 'adcolony.com',
  'vungle.com', 'chartboost.com', 'startappservice.com', 'lkqd.net', 'springserve.com',
  'fwmrm.net', 'innovid.com',
  // Trackers and session recorders
  'hotjar.com', 'mouseflow.com', 'crazyegg.com', 'fullstory.com', 'clarity.ms', 'app-measurement.com',
  'adjust.com', 'appsflyer.com', 'chartbeat.com', 'bluekai.com', 'krxd.net', 'demdex.net',
  'omtrdc.net', 'rlcdn.com', 'agkn.com', 'tapad.com', 'crwdcntrl.net', 'id5-sync.com',
  'mathtag.com', 'bounceexchange.com', 'connect.facebook.net', 'ads-twitter.com',
  'px.ads.linkedin.com', 'analytics.tiktok.com', 'bat.bing.com',
};

/// Paths that serve ads from a site's own host, which a host rule can't
/// block without breaking the site (YouTube serves video and ads from one
/// domain).
final adPathPattern = RegExp(
  r'^https?://([^/]+\.)?(youtube\.com|google\.com|googlevideo\.com)/(pagead/|ptracking|api/stats/ads|pcs/activeview|get_midroll_info)',
);

/// Hosts, cosmetic rules and scriptlets from one or more filter lists.
class FilterSet {
  FilterSet({
    Set<String>? hosts,
    Set<String>? thirdPartyHosts,
    Set<String>? allowHosts,
    Map<String, List<SiteRule>>? siteRules,
    List<SiteRule>? genericRules,
  }) : hosts = hosts ?? {},
       thirdPartyHosts = thirdPartyHosts ?? {},
       allowHosts = allowHosts ?? {},
       siteRules = siteRules ?? {},
       genericRules = genericRules ?? [];

  /// Blocked in any context.
  final Set<String> hosts;

  /// Blocked only when a page loads them from another site (`$third-party`).
  final Set<String> thirdPartyHosts;

  /// `@@||host^` exceptions: never blocked.
  final Set<String> allowHosts;

  /// Cosmetic and scriptlet rules, indexed by each hostname (or `name.*`
  /// entity) they list.
  final Map<String, List<SiteRule>> siteRules;

  /// Scriptlets and hide rules without a domain.
  final List<SiteRule> genericRules;

  int get networkRuleCount => hosts.length + thirdPartyHosts.length;
  int get siteRuleCount => siteRules.values.fold(0, (n, l) => n + l.length) + genericRules.length;

  /// Adds everything from [other]; exceptions stay exceptions.
  void addAll(FilterSet other) {
    hosts.addAll(other.hosts);
    thirdPartyHosts.addAll(other.thirdPartyHosts);
    allowHosts.addAll(other.allowHosts);
    for (final e in other.siteRules.entries) {
      (siteRules[e.key] ??= []).addAll(e.value);
    }
    genericRules.addAll(other.genericRules);
  }

  /// Rules that apply on [host]: hide selectors and scriptlet calls, with
  /// `#@#` exceptions and `~domain` exclusions resolved.
  ({List<String> hide, List<Scriptlet> scriptlets}) rulesFor(String host) {
    final seen = <SiteRule>{};
    final candidates = <SiteRule>[...genericRules];
    for (final key in _lookupKeys(host)) {
      for (final r in siteRules[key] ?? const <SiteRule>[]) {
        if (seen.add(r)) candidates.add(r);
      }
    }
    final hide = <String>{};
    final unhide = <String>{};
    final scriptlets = <String, Scriptlet>{};
    final unscript = <String>{};
    for (final r in candidates) {
      if (!r.appliesTo(host)) continue;
      switch (r) {
        case HideRule(:final selector, :final exception):
          (exception ? unhide : hide).add(selector);
        case ScriptletRule(:final scriptlet, :final exception):
          if (exception) {
            unscript.add(scriptlet.key);
          } else {
            scriptlets[scriptlet.key] = scriptlet;
          }
      }
    }
    return (
      hide: [
        for (final s in hide)
          if (!unhide.contains(s)) s,
      ],
      scriptlets: [
        for (final s in scriptlets.values)
          if (!unscript.contains(s.key)) s,
      ],
    );
  }
}

/// `a.b.example.com` -> itself, its parents, and `example.*`-style entities.
Iterable<String> _lookupKeys(String host) sync* {
  final labels = host.toLowerCase().split('.');
  for (var i = 0; i < labels.length; i++) {
    yield labels.sublist(i).join('.');
    // Entity: every label but the last (TLD) may be the name before `.*`.
    if (i < labels.length - 1) yield '${labels.sublist(i, labels.length - 1).join('.')}.*';
    if (i < labels.length - 2) yield '${labels.sublist(i, labels.length - 2).join('.')}.*';
  }
}

bool _domainMatches(String host, String pattern) {
  if (pattern.endsWith('.*')) return _lookupKeys(host).contains(pattern);
  return host == pattern || host.endsWith('.$pattern');
}

/// A cosmetic or scriptlet rule and the sites it is limited to.
sealed class SiteRule {
  SiteRule(this.include, this.exclude, this.exception);

  /// Empty means every site.
  final List<String> include;
  final List<String> exclude;
  final bool exception;

  bool appliesTo(String host) {
    if (exclude.any((d) => _domainMatches(host, d))) return false;
    return include.isEmpty || include.any((d) => _domainMatches(host, d));
  }
}

class HideRule extends SiteRule {
  HideRule(super.include, super.exclude, super.exception, this.selector);
  final String selector;
}

class ScriptletRule extends SiteRule {
  ScriptletRule(super.include, super.exclude, super.exception, this.scriptlet);
  final Scriptlet scriptlet;
}

/// One `+js(name, args...)` call, name already resolved from its aliases.
class Scriptlet {
  const Scriptlet(this.name, this.args);
  final String name;
  final List<String> args;

  String get key => '$name(${args.join(',')})';

  Map<String, Object> toJson() => {'n': name, 'a': args};
}

/// uBlock scriptlet names and aliases DownloadHQ implements, mapped to one
/// canonical name. Anything else in a list is skipped.
const scriptletAliases = {
  'set-constant': 'set',
  'set': 'set',
  'abort-on-property-read': 'aopr',
  'aopr': 'aopr',
  'abort-on-property-write': 'aopw',
  'aopw': 'aopw',
  'abort-current-script': 'acs',
  'acs': 'acs',
  'abort-current-inline-script': 'acs',
  'acis': 'acs',
  'json-prune': 'json-prune',
  'no-setTimeout-if': 'nostif',
  'nostif': 'nostif',
  'prevent-setTimeout': 'nostif',
  'no-setInterval-if': 'nosiif',
  'nosiif': 'nosiif',
  'prevent-setInterval': 'nosiif',
  'addEventListener-defuser': 'aeld',
  'aeld': 'aeld',
  'prevent-addEventListener': 'aeld',
  'no-window-open-if': 'nowoif',
  'nowoif': 'nowoif',
  'prevent-window-open': 'nowoif',
  'remove-attr': 'ra',
  'ra': 'ra',
};

/// Selectors that only uBlock's own engine understands (procedural and
/// HTML filters). CSS can't express them, and one invalid selector would
/// void the rule.
final _procedural = RegExp(
  r':(-abp-|has-text|upward|xpath|remove|style|matches-|min-text-length|watch-attr|others|if\(|if-not|nth-ancestor|spath|matches-path|matches-attr|matches-prop|matches-media|shadow)',
);

/// Network options a host-wide block honours. Rules restricted to certain
/// pages (`$domain=`), first party, or rewriting (`$redirect`, `$csp`) are
/// narrower than a host block and are skipped.
const _hostWideOptions = {
  'third-party',
  '3p',
  'all',
  'important',
  'doc',
  'document',
  'popup',
  'script',
  'image',
  'subdocument',
  'frame',
  'xmlhttprequest',
  'xhr',
  'media',
  'object',
  'ping',
  'other',
  'websocket',
  'stylesheet',
  'css',
  'font',
  'beacon',
};

final _hostName = RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)+$');
const _notHosts = {'localhost', 'localhost.localdomain', 'local', 'broadcasthost', '0.0.0.0'};

/// Reads a filter list in any of the shapes ad block lists are published
/// in: Adblock/uBlock syntax, hosts files (`0.0.0.0 ads.example`) and plain
/// domain lists. Rules the engine can't honour are skipped, never guessed.
FilterSet parseFilterList(String text) {
  final out = FilterSet();
  for (var line in const LineSplitter().convert(text)) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('!') || line.startsWith('[')) continue;
    if (line.startsWith('#') && !line.startsWith('##') && !line.startsWith('#@#')) continue;

    final cosmetic = RegExp(r'^([^#\s]*)(##|#@#)(.+)$').firstMatch(line);
    if (cosmetic != null) {
      _addSiteRule(out, cosmetic.group(1)!, cosmetic.group(2) == '#@#', cosmetic.group(3)!);
      continue;
    }
    // Other `#?#`, `#$#`, `#%#` extensions belong to other blockers.
    if (line.contains('#?#') || line.contains(r'#$#') || line.contains('#%#')) continue;

    final lower = line.toLowerCase();
    final exception = lower.startsWith('@@');
    final net = RegExp(r'^(?:@@)?\|\|([a-z0-9._-]+)\^(?:\$(.*))?$').firstMatch(lower);
    if (net != null) {
      final host = net.group(1)!;
      if (!_hostName.hasMatch(host)) continue;
      final opts = (net.group(2) ?? '').split(',').where((o) => o.isNotEmpty).toList();
      if (exception) {
        // Only unconditional exceptions; `@@||x^$generichide` and the like
        // don't mean "never block x".
        if (opts.isEmpty || opts.every((o) => o == 'document' || o == 'doc' || o == 'all')) {
          out.allowHosts.add(host);
        }
        continue;
      }
      if (!opts.every(_hostWideOptions.contains)) continue;
      (opts.contains('third-party') || opts.contains('3p') ? out.thirdPartyHosts : out.hosts).add(host);
      continue;
    }
    if (exception || line.contains('/') || line.contains(r'$') || line.contains('*')) continue;

    final hash = lower.indexOf(' #');
    final parts = (hash >= 0 ? lower.substring(0, hash) : lower).trim().split(RegExp(r'\s+'));
    String? host;
    if (parts.length == 2 && const {'0.0.0.0', '127.0.0.1', '::', '::1'}.contains(parts[0])) {
      host = parts[1];
    } else if (parts.length == 1) {
      host = parts[0];
    }
    if (host != null && _hostName.hasMatch(host) && !_notHosts.contains(host)) out.hosts.add(host);
  }
  return out;
}

void _addSiteRule(FilterSet out, String domains, bool exception, String body) {
  final include = <String>[];
  final exclude = <String>[];
  for (final d in domains.toLowerCase().split(',')) {
    if (d.isEmpty) continue;
    if (d.startsWith('~')) {
      exclude.add(d.substring(1));
    } else {
      include.add(d);
    }
  }
  // Regex and path-limited domains (`/re/`, `example.com/path`) aren't hosts.
  if ([...include, ...exclude].any((d) => d.contains('/'))) return;

  final SiteRule rule;
  if (body.startsWith('+js(') && body.endsWith(')')) {
    final args = splitScriptletArgs(body.substring(4, body.length - 1));
    if (args.isEmpty) {
      // `#@#+js()` switches every scriptlet off for those sites; rare and
      // not worth a special case.
      return;
    }
    final name = scriptletAliases[args.first.replaceFirst(RegExp(r'\.js$'), '')];
    if (name == null) return;
    rule = ScriptletRule(include, exclude, exception, Scriptlet(name, args.sublist(1)));
  } else {
    if (body.startsWith('^') || body.startsWith('+') || _procedural.hasMatch(body)) return;
    rule = HideRule(include, exclude, exception, body);
  }
  if (include.isEmpty) {
    // Generic hide rules are skipped: EasyList has over 13,000 and applying
    // them to every page costs more than it saves on a phone. Generic
    // scriptlets and exceptions are few and kept.
    if (rule is HideRule && !exception) return;
    out.genericRules.add(rule);
    return;
  }
  for (final d in include) {
    (out.siteRules[d] ??= []).add(rule);
  }
}

/// Splits `a, b\, c, 'd, e'` into `[a, b, c, d, e]`-style scriptlet args,
/// honouring backslash-escaped commas and quoted values.
List<String> splitScriptletArgs(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var started = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == r'\' && i + 1 < s.length && s[i + 1] == ',') {
      buf.write(',');
      i++;
      continue;
    }
    if ((c == '"' || c == "'") && buf.toString().trim().isEmpty) {
      quote = c;
      buf.clear();
      started = true;
      continue;
    }
    if (c == ',') {
      out.add(started ? buf.toString() : buf.toString().trim());
      buf.clear();
      started = false;
      continue;
    }
    buf.write(c);
  }
  final last = started ? buf.toString() : buf.toString().trim();
  if (last.isNotEmpty || out.isNotEmpty) out.add(last);
  return out;
}

/// True when [host] or a parent domain of it is in [hosts].
bool hostListed(String host, Set<String> hosts) {
  var h = host.toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  while (h.isNotEmpty) {
    if (hosts.contains(h)) return true;
    final dot = h.indexOf('.');
    if (dot < 0) return false;
    h = h.substring(dot + 1);
  }
  return false;
}

/// Last two labels, or three for common second-level country domains
/// (`bbc.co.uk`). Good enough to tell first party from third party.
String siteOf(String host) {
  final l = host.toLowerCase().split('.');
  if (l.length <= 2) return l.join('.');
  final sld = l[l.length - 2];
  final threeLabels =
      sld.length <= 3 && const {'co', 'com', 'net', 'org', 'gov', 'ac', 'edu', 'or', 'ne', 'go'}.contains(sld);
  return l.sublist(l.length - (threeLabels ? 3 : 2)).join('.');
}

/// Decides whether the browser should refuse a navigation to [url].
/// [pageUrl] is the page the user is on (for frames and pop-ups); blocking
/// is off entirely on sites in [pausedHosts].
bool shouldBlockNavigation(
  String url,
  FilterSet filters, {
  required bool isMainFrame,
  String? pageUrl,
  Set<String> pausedHosts = const {},
}) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  final page = pageUrl == null ? null : Uri.tryParse(pageUrl);
  if (page != null && page.host.isNotEmpty && hostListed(page.host, pausedHosts)) return false;
  // Ad redirects love app-store and intent links; the web view can't open
  // them and would show an error page instead.
  if (!const {'http', 'https', 'about', 'data', 'blob', 'file', 'javascript'}.contains(u.scheme)) return true;
  if (u.scheme != 'http' && u.scheme != 'https') return false;
  if (hostListed(u.host, filters.allowHosts)) return false;
  if (adPathPattern.hasMatch(url)) return true;
  if (hostListed(u.host, filters.hosts)) return true;
  // A page you open yourself is first party; a frame or pop-up from another
  // site isn't.
  final thirdParty = !isMainFrame && page != null && siteOf(page.host) != siteOf(u.host);
  return thirdParty && hostListed(u.host, filters.thirdPartyHosts);
}

/// Hosts worth sending to the page script, most valuable first, at most
/// [limit]. The page script runs in every frame of every page, so the full
/// EasyList + EasyPrivacy set (100,000+ hosts) would slow a phone down;
/// subdomains of an already listed host add nothing and go first.
List<String> compactHosts(Iterable<String> hosts, int limit) {
  final all = hosts.toSet();
  final out = <String>[];
  for (final h in hosts) {
    if (out.length >= limit) break;
    final dot = h.indexOf('.');
    if (dot > 0 && hostListed(h.substring(dot + 1), all)) continue;
    out.add(h);
  }
  return out;
}

/// Hides ad containers on any site. Conservative on purpose: generic rules
/// that guess (`.ad`, `[class*=ad]`) break real pages.
const genericHideSelectors = [
  'ins.adsbygoogle',
  '[id^="google_ads_iframe"]',
  '[id^="div-gpt-ad"]',
  '[data-google-query-id]',
  '[data-ad-slot]',
  'amp-ad',
  'amp-embed[type="taboola"]',
  'iframe[src*="doubleclick.net"]',
  'iframe[src*="googlesyndication.com"]',
  'iframe[src*="amazon-adsystem.com"]',
  'iframe[id^="aswift_"]',
  '[id^="taboola-"]',
  '.trc_related_container',
  '.OUTBRAIN',
  '.mgbox',
];

/// YouTube's ad renderers (www, m. and music.), after uBlock Origin's and
/// EasyList's YouTube sections.
const youtubeHideSelectors = [
  '#masthead-ad',
  '#player-ads',
  'ytd-ad-slot-renderer',
  'ytd-in-feed-ad-layout-renderer',
  'ytd-display-ad-renderer',
  'ytd-promoted-sparkles-web-renderer',
  'ytd-promoted-sparkles-text-search-renderer',
  'ytd-promoted-video-renderer',
  'ytd-companion-slot-renderer',
  'ytd-action-companion-ad-renderer',
  'ytd-player-legacy-desktop-watch-ads-renderer',
  'ytd-banner-promo-renderer',
  'ytd-statement-banner-renderer',
  'ytd-search-pyv-renderer',
  'ytd-merch-shelf-renderer',
  'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)',
  'ytm-promoted-sparkles-web-renderer',
  'ytm-promoted-sparkles-text-search-renderer',
  'ytm-promoted-video-renderer',
  'ytm-companion-ad-renderer',
  'ytm-companion-slot',
  'ytm-ad-slot-renderer',
  'ad-slot-renderer',
  'ytm-rich-item-renderer:has(ad-slot-renderer)',
  'ytm-item-section-renderer:has(ytm-promoted-sparkles-web-renderer)',
  'ytm-statement-banner-renderer',
  'ytm-mealbar-promo-renderer',
  'ytmusic-mealbar-promo-renderer',
  'ytmusic-statement-banner-renderer',
  '.ytp-ad-overlay-container',
  '.ytp-featured-product',
];

/// Name of the JavaScript channel the page script reports block counts on.
const adblockChannel = 'DownloadHQAdblock';

/// The document-start script for pages on [siteHost]. [hosts] and
/// [thirdPartyHosts] are embedded so the script also works in frames that
/// can't reach the app. The page script is the fallback for what navigation
/// blocking can't see, so it only needs the most common hosts (see
/// [compactHosts]).
String buildAdblockScript({
  required String siteHost,
  required List<String> hosts,
  required List<String> thirdPartyHosts,
  required Set<String> allowHosts,
  required List<String> hide,
  required List<Scriptlet> scriptlets,
  Set<String> pausedHosts = const {},
}) {
  final css = [...genericHideSelectors, ...hide];
  return '''
const SITE_HOST = ${jsonEncode(siteHost)};
// Once per document and site: a late run with the right site's rules still
// applies them after an early one built for another site.
if (globalThis['__dhqAdblock:' + SITE_HOST]) return;
globalThis['__dhqAdblock:' + SITE_HOST] = true;
const HOSTS = new Set(${jsonEncode(hosts)});
const HOSTS_3P = new Set(${jsonEncode(thirdPartyHosts)});
const ALLOW = new Set(${jsonEncode(allowHosts.toList())});
const PAUSED = new Set(${jsonEncode(pausedHosts.toList())});
const HIDE = ${jsonEncode(css)};
const YOUTUBE_HIDE = ${jsonEncode(youtubeHideSelectors)};
const SCRIPTLETS = ${jsonEncode(scriptlets.map((s) => s.toJson()).toList())};
const AD_PATH = new RegExp(${jsonEncode(adPathPattern.pattern)});
$_engineJs
''';
}

/// The page half of the engine. Plain ES2017, no dependencies; tested with
/// node in `test/adblock_js_test.dart`.
const _engineJs = r'''
const listed = (host, set) => {
  let h = String(host || '').toLowerCase();
  while (h) {
    if (set.has(h)) return true;
    const i = h.indexOf('.');
    if (i < 0) return false;
    h = h.slice(i + 1);
  }
  return false;
};
const siteOf = (host) => {
  const l = String(host).toLowerCase().split('.');
  if (l.length <= 2) return l.join('.');
  const sld = l[l.length - 2];
  const three = sld.length <= 3 && ['co','com','net','org','gov','ac','edu','or','ne','go'].includes(sld);
  return l.slice(l.length - (three ? 3 : 2)).join('.');
};
// The page the user sees decides the pause, also inside its frames.
let topHost = location.hostname;
try { topHost = window.top.location.hostname; } catch (e) {
  try {
    const a = location.ancestorOrigins;
    if (a && a.length) topHost = new URL(a[a.length - 1]).hostname;
    else if (document.referrer) topHost = new URL(document.referrer).hostname;
  } catch (e2) {}
}
if (listed(topHost, PAUSED)) return;
const pageSite = siteOf(location.hostname);

let count = 0, reportTimer = 0;
const report = () => {
  count++;
  if (reportTimer) return;
  reportTimer = setTimeout(() => {
    reportTimer = 0;
    try {
      if (window === window.top && globalThis.DownloadHQAdblock) globalThis.DownloadHQAdblock.postMessage(String(count));
    } catch (e) {}
  }, 400);
};
const blocked = (url) => {
  if (!url) return false;
  try {
    const u = new URL(String(url), location.href);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
    if (listed(u.hostname, ALLOW)) return false;
    if (AD_PATH.test(u.href) || listed(u.hostname, HOSTS)) return true;
    return siteOf(u.hostname) !== pageSite && listed(u.hostname, HOSTS_3P);
  } catch (e) { return false; }
};
globalThis.__dhqBlocked = blocked;

// Network: the page's own requests.
const nativeFetch = window.fetch;
if (nativeFetch) {
  window.fetch = function (input, init) {
    const url = input && typeof input === 'object' && 'url' in input ? input.url : input;
    if (blocked(url)) { report(); return Promise.reject(new TypeError('Failed to fetch')); }
    return nativeFetch.apply(this, arguments);
  };
}
const XHR = window.XMLHttpRequest && XMLHttpRequest.prototype;
if (XHR) {
  const open = XHR.open, send = XHR.send;
  XHR.open = function (method, url) {
    this.__dhqBlocked = blocked(url);
    return open.apply(this, arguments);
  };
  XHR.send = function () {
    if (!this.__dhqBlocked) return send.apply(this, arguments);
    report();
    setTimeout(() => {
      this.dispatchEvent(new Event('error'));
      this.dispatchEvent(new Event('loadend'));
    }, 0);
  };
}
if (navigator.sendBeacon) {
  const beacon = navigator.sendBeacon.bind(navigator);
  navigator.sendBeacon = (url, data) => blocked(url) ? (report(), true) : beacon(url, data);
}
// Elements: scripts, frames and pixels pointed at ad hosts never load.
const guardSrc = (proto, blank) => {
  if (!proto) return;
  const d = Object.getOwnPropertyDescriptor(proto, 'src');
  if (!d || !d.set) return;
  Object.defineProperty(proto, 'src', {
    configurable: true, enumerable: d.enumerable, get: d.get,
    set(v) {
      if (blocked(v)) { report(); this.__dhqAd = true; return d.set.call(this, blank); }
      return d.set.call(this, v);
    },
  });
};
guardSrc(window.HTMLScriptElement && HTMLScriptElement.prototype, 'data:text/javascript,');
guardSrc(window.HTMLIFrameElement && HTMLIFrameElement.prototype, 'about:blank');
guardSrc(window.HTMLImageElement && HTMLImageElement.prototype, 'data:image/gif;base64,R0lGODlhAQABAAAAACw=');
if (window.Element) {
  const setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (String(name).toLowerCase() === 'src' && /^(SCRIPT|IFRAME|IMG)$/.test(this.tagName) && blocked(value)) {
      this.src = value; // routed through the guarded setter
      return;
    }
    return setAttr.apply(this, arguments);
  };
}
// Pop-ups and pop-unders: ad hosts never, others only on a real tap.
const nativeOpen = window.open;
window.open = function (url) {
  const active = navigator.userActivation ? navigator.userActivation.isActive : true;
  if (blocked(url) || !active) { report(); return null; }
  return nativeOpen.apply(this, arguments);
};
// Frames and scripts written into the HTML itself.
const sweep = (node) => {
  if (node.nodeType !== 1) return;
  const check = (el) => {
    if (!el.__dhqAd && /^(SCRIPT|IFRAME)$/.test(el.tagName) && blocked(el.getAttribute('src'))) {
      el.__dhqAd = true; report(); el.remove();
    }
  };
  check(node);
  if (node.querySelectorAll) node.querySelectorAll('script[src],iframe[src]').forEach(check);
};
if (window.MutationObserver) {
  new MutationObserver((muts) => { for (const m of muts) m.addedNodes.forEach(sweep); })
    .observe(document, { childList: true, subtree: true });
}

// Cosmetic: one rule per selector, so one the engine can't parse doesn't
// void the rest.
const addStyle = (selectors) => {
  if (!selectors.length) return;
  const css = selectors.map((s) => s + '{display:none!important}').join('\n');
  const put = () => {
    const s = document.createElement('style');
    s.textContent = css;
    (document.head || document.documentElement).appendChild(s);
  };
  document.documentElement ? put() : document.addEventListener('DOMContentLoaded', put);
};
addStyle(HIDE);

// uBlock scriptlets.
const noop = () => {};
const constValue = (v) => {
  switch (v) {
    case 'undefined': return undefined;
    case 'false': return false;
    case 'true': return true;
    case 'null': return null;
    case 'noopFunc': return noop;
    case 'trueFunc': return () => true;
    case 'falseFunc': return () => false;
    case 'emptyObj': case '{}': return {};
    case 'emptyArr': case '[]': return [];
    case "''": case '': return '';
    case 'yes': return 'yes';
    case 'no': return 'no';
  }
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return undefined;
};
const needleRe = (s) => {
  if (!s) return null;
  const m = /^\/(.+)\/([gimsu]*)$/.exec(s);
  try { return m ? new RegExp(m[1], m[2]) : new RegExp(s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')); } catch (e) { return null; }
};
// Defines `a.b.c` on `root`, waiting for missing parents to be assigned.
const trapPath = (root, path, handler) => {
  const dot = path.indexOf('.');
  const prop = dot < 0 ? path : path.slice(0, dot);
  const rest = dot < 0 ? '' : path.slice(dot + 1);
  if (!rest) return handler(root, prop);
  let value = root[prop];
  if (value && typeof value === 'object') return trapPath(value, rest, handler);
  try {
    Object.defineProperty(root, prop, {
      configurable: true,
      get() { return value; },
      set(v) { value = v; if (v && typeof v === 'object') trapPath(v, rest, handler); },
    });
  } catch (e) {}
};
const abortError = () => new ReferenceError('DownloadHQ blocked this');
const pruneJson = (obj, paths) => {
  if (!obj || typeof obj !== 'object') return obj;
  let hit = false;
  for (const path of paths) {
    const parts = path.split('.');
    const walk = (o, i) => {
      if (!o || typeof o !== 'object') return;
      const k = parts[i];
      if (k === '[-]' && Array.isArray(o)) return; // array pruning handled by caller rules
      if (i === parts.length - 1) { if (k in o) { delete o[k]; hit = true; } return; }
      if (k === '[]' && Array.isArray(o)) { o.forEach((x) => walk(x, i + 1)); return; }
      walk(o[k], i + 1);
    };
    walk(obj, 0);
  }
  if (hit) report();
  return obj;
};
const jsonPrunePaths = [];
const run = {
  'set': ([path, v]) => trapPath(window, path, (o, p) => {
    const value = constValue(v);
    try { Object.defineProperty(o, p, { configurable: true, get: () => value, set: noop }); } catch (e) {}
  }),
  'aopr': ([path]) => trapPath(window, path, (o, p) => {
    try { Object.defineProperty(o, p, { configurable: true, get() { throw abortError(); }, set: noop }); } catch (e) {}
  }),
  'aopw': ([path]) => trapPath(window, path, (o, p) => {
    let v = o[p];
    try { Object.defineProperty(o, p, { configurable: true, get: () => v, set() { throw abortError(); } }); } catch (e) {}
  }),
  'acs': ([path, needle]) => {
    const re = needleRe(needle);
    trapPath(window, path, (o, p) => {
      let v = o[p];
      const check = () => {
        const s = document.currentScript;
        if (s && (!re || re.test(s.src || s.textContent))) throw abortError();
      };
      try { Object.defineProperty(o, p, { configurable: true, get() { check(); return v; }, set(x) { check(); v = x; } }); } catch (e) {}
    });
  },
  'json-prune': ([props]) => { if (props) jsonPrunePaths.push(...props.split(/\s+/)); },
  'nostif': ([needle, delay]) => {
    const re = needleRe(needle), native = window.setTimeout;
    window.setTimeout = function (fn, ms) {
      const s = String(fn);
      if ((!re || re.test(s)) && (!delay || String(ms) === String(delay))) { report(); return 0; }
      return native.apply(this, arguments);
    };
  },
  'nosiif': ([needle, delay]) => {
    const re = needleRe(needle), native = window.setInterval;
    window.setInterval = function (fn, ms) {
      const s = String(fn);
      if ((!re || re.test(s)) && (!delay || String(ms) === String(delay))) { report(); return 0; }
      return native.apply(this, arguments);
    };
  },
  'aeld': ([type, needle]) => {
    const tr = needleRe(type), re = needleRe(needle), native = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (t, fn) {
      if ((!tr || tr.test(t)) && (!re || re.test(String(fn)))) return;
      return native.apply(this, arguments);
    };
  },
  'nowoif': ([needle]) => {
    const re = needleRe(needle), native = window.open;
    window.open = function (url) {
      if (!re || re.test(String(url))) { report(); return null; }
      return native.apply(this, arguments);
    };
  },
  'ra': ([attrs, selector]) => {
    if (!attrs) return;
    const names = attrs.split(/\s*\|\s*/);
    const sel = selector || names.map((a) => '[' + a + ']').join(',');
    const clean = () => document.querySelectorAll(sel).forEach((el) => names.forEach((a) => el.removeAttribute(a)));
    document.addEventListener('DOMContentLoaded', clean);
    if (window.MutationObserver) new MutationObserver(clean).observe(document, { childList: true, subtree: true });
  },
};
for (const s of SCRIPTLETS) {
  try { if (run[s.n]) run[s.n](s.a); } catch (e) {}
}

// YouTube: strip ads out of player responses before the player reads them
// (uBlock's json-prune and set rules) and fast-forward any that get through.
const onYouTube = /(^|\.)(youtube\.com|youtube-nocookie\.com|youtubekids\.com)$/.test(location.hostname);
if (onYouTube) {
  addStyle(YOUTUBE_HIDE);
  jsonPrunePaths.push('adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams',
    'playerResponse.adPlacements', 'playerResponse.playerAds', 'playerResponse.adSlots');
}
const reelAd = (e) => e && e.command && e.command.reelWatchEndpoint &&
  e.command.reelWatchEndpoint.adClientParams && e.command.reelWatchEndpoint.adClientParams.isAd;
const prune = (o) => {
  if (!o || typeof o !== 'object') return o;
  try {
    pruneJson(o, jsonPrunePaths);
    if (onYouTube && Array.isArray(o.entries) && o.entries.some(reelAd)) {
      o.entries = o.entries.filter((e) => !reelAd(e));
      report();
    }
  } catch (e) {}
  return o;
};
if (jsonPrunePaths.length) {
  const parse = JSON.parse;
  JSON.parse = function () { return prune(parse.apply(this, arguments)); };
  if (window.Response) {
    const json = Response.prototype.json;
    Response.prototype.json = function () { return json.apply(this, arguments).then(prune); };
  }
}
if (onYouTube) {
  for (const name of ['ytInitialPlayerResponse', 'playerResponse']) {
    let value;
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        get() { return value; },
        set(v) { value = prune(v); },
      });
    } catch (e) {}
  }
  setInterval(() => {
    const player = document.querySelector('.ad-showing, .ad-interrupting');
    if (!player) return;
    const v = player.querySelector('video');
    if (v) {
      v.muted = true;
      if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
      else v.playbackRate = 16;
    }
    const skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button');
    if (skip) skip.click();
  }, 400);
}
''';
