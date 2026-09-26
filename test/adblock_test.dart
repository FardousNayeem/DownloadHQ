import 'dart:convert';
import 'dart:io';

import 'package:downloadhq/domain/adblock.dart';
import 'package:flutter_test/flutter_test.dart';

const _list = r'''
[Adblock Plus 2.0]
! Title: test
||ads.example^
||tracker.example^$third-party
||cdn.example^$script,domain=news.example
@@||ads.example^$generichide
@@||good.example^
||good.example^
/banner/*/img^
example.com##.sponsored
example.com,~shop.example.com##.promo
example.*##.ent
news.example#@#.sponsored
example.com##.x:has-text(Ad)
##.generic-ad
example.com##+js(set, foo.bar, true)
example.com##+js(nostif, adblock, 1000)
example.com##+js(unknown-scriptlet, x)
example.com##+js(json-prune, a.b c)
0.0.0.0 hosts.example
127.0.0.1 localhost
plain.example
''';

void main() {
  final f = parseFilterList(_list);

  test('network rules: host-wide ones kept, narrower ones skipped', () {
    expect(f.hosts, containsAll(['ads.example', 'hosts.example', 'plain.example']));
    expect(f.hosts, isNot(contains('cdn.example'))); // $domain= is page-specific
    expect(f.hosts, isNot(contains('localhost')));
    expect(f.thirdPartyHosts, {'tracker.example'});
    // `$generichide` is not "never block"; a bare exception is.
    expect(f.allowHosts, {'good.example'});
  });

  test('cosmetic rules resolve domains, exclusions, entities and exceptions', () {
    final r = f.rulesFor('www.example.com');
    expect(r.hide, containsAll(['.sponsored', '.promo', '.ent']));
    expect(r.hide, isNot(contains('.x:has-text(Ad)'))); // procedural: uBlock only
    expect(r.hide, isNot(contains('.generic-ad'))); // generic hides skipped
    expect(f.rulesFor('shop.example.com').hide, isNot(contains('.promo')));
    expect(f.rulesFor('example.co.uk').hide, contains('.ent'));
    expect(f.rulesFor('other.org').hide, isEmpty);
  });

  test('scriptlets: aliases resolved, unknown ones dropped', () {
    final s = f.rulesFor('example.com').scriptlets;
    expect(s.map((x) => x.name), unorderedEquals(['set', 'nostif', 'json-prune']));
    expect(s.firstWhere((x) => x.name == 'set').args, ['foo.bar', 'true']);
  });

  test('scriptlet args honour escapes and quotes', () {
    expect(splitScriptletArgs(r"set, a.b, 'x, y'"), ['set', 'a.b', 'x, y']);
    expect(splitScriptletArgs(r'nostif, a\, b, 500'), ['nostif', 'a, b', '500']);
  });

  test('host matching covers subdomains only', () {
    expect(hostListed('x.ads.example', {'ads.example'}), isTrue);
    expect(hostListed('badads.example', {'ads.example'}), isFalse);
    expect(siteOf('a.b.bbc.co.uk'), 'bbc.co.uk');
    expect(siteOf('m.youtube.com'), 'youtube.com');
  });

  test('navigation blocking', () {
    bool block(String url, {bool main = true, String? page, Set<String> paused = const {}}) =>
        shouldBlockNavigation(url, f, isMainFrame: main, pageUrl: page, pausedHosts: paused);
    expect(block('https://ads.example/x'), isTrue);
    expect(block('https://good.example/'), isFalse); // exception wins
    expect(block('https://www.youtube.com/pagead/x'), isTrue);
    expect(block('https://www.youtube.com/watch?v=a'), isFalse);
    expect(block('intent://x#Intent;end'), isTrue);
    expect(block('market://details?id=x'), isTrue);
    // Third-party only rules: not when you open the site yourself.
    expect(block('https://tracker.example/'), isFalse);
    expect(block('https://tracker.example/', main: false, page: 'https://news.org/'), isTrue);
    expect(block('https://ads.example/x', page: 'https://site.org/', paused: {'site.org'}), isFalse);
  });

  test('compact host list drops redundant subdomains and caps size', () {
    expect(compactHosts(['a.com', 'x.a.com', 'b.com', 'c.com'], 2), ['a.com', 'b.com']);
  });

  group('page script (node)', () {
    final node = Process.runSync('which', ['node']).exitCode == 0;

    Future<Map<String, dynamic>> run(String host, String probe) async {
      final r = f.rulesFor(host);
      final script = buildAdblockScript(
        siteHost: host,
        hosts: ['ads.example', 'doubleclick.net'],
        thirdPartyHosts: ['tracker.example'],
        allowHosts: f.allowHosts,
        hide: r.hide,
        scriptlets: r.scriptlets,
      );
      final dir = await Directory.systemTemp.createTemp('dhq_js');
      final file = File('${dir.path}/h.js')
        ..writeAsStringSync('''
globalThis.window = globalThis;
window.top = window;
globalThis.location = new URL('https://$host/page');
globalThis.navigator = { userActivation: { isActive: false } };
const styles = [];
globalThis.document = {
  referrer: '', currentScript: null, head: null,
  documentElement: { appendChild: (s) => styles.push(s.textContent) },
  createElement: () => ({}), addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
};
window.open = () => 'opened';
(function () {
$script
}).call(globalThis);
const out = {};
$probe
out.styles = styles.join('\\n');
console.log(JSON.stringify(out));
process.exit(0);
''');
      final res = await Process.run('node', [file.path]);
      await dir.delete(recursive: true);
      expect(res.exitCode, 0, reason: res.stderr.toString());
      return (jsonDecode(res.stdout as String) as Map).cast<String, dynamic>();
    }

    test('blocks listed hosts, respects third party and exceptions', () async {
      final o = await run('news.org', '''
out.ad = __dhqBlocked('https://x.ads.example/a.js');
out.first = __dhqBlocked('https://news.org/a.js');
out.tp = __dhqBlocked('https://tracker.example/p');
out.good = __dhqBlocked('https://good.example/');
out.popup = window.open('https://news.org/other');
''');
      expect(o['ad'], isTrue);
      expect(o['first'], isFalse);
      expect(o['tp'], isTrue);
      expect(o['good'], isFalse);
      expect(o['popup'], isNull); // no user gesture
    }, skip: !node);

    test('runs scriptlets and site cosmetics', () async {
      final o = await run('example.com', '''
window.foo = {};
out.bar = window.foo.bar;
out.pruned = JSON.parse('{"a":{"b":1,"k":2},"c":3,"d":4}');
''');
      expect(o['bar'], isTrue);
      expect(o['pruned'], {
        'a': {'k': 2},
        'd': 4,
      });
      expect(o['styles'], contains('.sponsored{display:none!important}'));
    }, skip: !node);

    test('prunes YouTube player ads', () async {
      final o = await run('m.youtube.com', '''
out.pr = JSON.parse('{"playerResponse":{"adPlacements":[1],"videoDetails":{}},"adSlots":[2]}');
window.ytInitialPlayerResponse = { adPlacements: [1], playerAds: [2], streamingData: {} };
out.initial = window.ytInitialPlayerResponse;
''');
      expect(o['pr'], {
        'playerResponse': {'videoDetails': {}},
      });
      expect(o['initial'], {'streamingData': {}});
      expect(o['styles'], contains('ytm-promoted-sparkles-web-renderer'));
    }, skip: !node);
  });
}
