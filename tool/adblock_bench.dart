// Manual check of the ad block engine against real filter lists.
// dart run tool/adblock_bench.dart <list.txt>...
import 'dart:io';
import 'package:downloadhq/domain/adblock.dart';

void main(List<String> files) {
  final sw = Stopwatch()..start();
  final all = FilterSet(hosts: {...builtinAdHosts});
  for (final f in files) {
    all.addAll(parseFilterList(File(f).readAsStringSync()));
  }
  stdout.writeln(
    'parsed in ${sw.elapsedMilliseconds}ms: ${all.hosts.length} hosts, '
    '${all.thirdPartyHosts.length} 3p, ${all.allowHosts.length} allow, ${all.siteRuleCount} site rules',
  );
  sw.reset();
  final hosts = compactHosts([...builtinAdHosts, ...all.hosts], 20000);
  final hosts3p = compactHosts(all.thirdPartyHosts, 8000);
  stdout.writeln('compacted in ${sw.elapsedMilliseconds}ms');
  for (final site in ['m.youtube.com', 'www.youtube.com', 'www.cnn.com', 'example.org']) {
    sw.reset();
    final r = all.rulesFor(site);
    final js = buildAdblockScript(
      siteHost: site,
      hosts: hosts,
      thirdPartyHosts: hosts3p,
      allowHosts: all.allowHosts,
      hide: r.hide,
      scriptlets: r.scriptlets,
    );
    stdout.writeln(
      '$site: ${r.hide.length} hide, ${r.scriptlets.map((s) => s.name).toSet()} '
      'script ${(js.length / 1024).round()} KB in ${sw.elapsedMilliseconds}ms',
    );
  }
}
