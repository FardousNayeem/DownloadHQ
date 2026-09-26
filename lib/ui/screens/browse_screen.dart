import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:webview_all/webview_all.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../domain/adblock.dart';
import '../../services/adblock_service.dart';
import '../../services/grab_service.dart';
import '../widgets/common.dart';
import '../widgets/grab_sheet.dart';

/// In-app browser, and the screen the app opens on. Pages load with the ad
/// blocker in front of them; any page you open is also checked by yt-dlp in
/// the background, and the bar under the page says what it found.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.visible});

  /// False while another tab is shown or something covers this screen.
  final ValueListenable<bool> visible;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  static const quickSites = [
    ('YouTube', 'https://m.youtube.com', PhosphorIconsRegular.youtubeLogo),
    ('YouTube Music', 'https://music.youtube.com', PhosphorIconsRegular.musicNotes),
    ('SoundCloud', 'https://soundcloud.com', PhosphorIconsRegular.soundcloudLogo),
    ('Bandcamp', 'https://bandcamp.com', PhosphorIconsRegular.vinylRecord),
    ('Internet Archive', 'https://archive.org/details/audio', PhosphorIconsRegular.archive),
    ('Dailymotion', 'https://www.dailymotion.com', PhosphorIconsRegular.filmStrip),
    ('Vimeo', 'https://vimeo.com/watch', PhosphorIconsRegular.playCircle),
  ];

  final _address = TextEditingController();
  final _focus = FocusNode();
  late final WebViewController _web;
  bool _ready = false;
  bool _userScripts = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  int _progress = 0;
  String _url = '';

  /// Host the registered ad block script was built for.
  String? _scriptHost;
  StreamSubscription<String>? _shareSub;
  late final AdblockService _adblock;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context);
    _adblock = s.adblock;
    _shareSub = s.share.links.listen(_open);
    _adblock.addListener(_onAdblockChanged);
    _start(s.share.takePending() ?? s.settings.value.home);
  }

  Future<void> _start(String first) async {
    final s = AppScope.of(context);
    _web = WebViewController();
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    try {
      _userScripts = await _web.isUserScriptInjectionSupported(WebViewUserScriptInjectionTime.documentStart);
    } catch (_) {
      _userScripts = false;
    }
    try {
      await _web.addJavaScriptChannel(
        adblockChannel,
        onMessageReceived: (m) => s.adblock.reportPageCount(int.tryParse(m.message) ?? 0),
      );
    } catch (_) {
      // Counts are a nicety; blocking works without the channel.
    }
    await _web.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        onPageStarted: _onPageStarted,
        onPageFinished: (_) => _refreshHistory(),
        onUrlChange: (c) => c.url == null ? null : _onUrl(c.url!),
      ),
    );
    if (!mounted) return;
    setState(() => _ready = true);
    await _load(toUri(first));
  }

  Future<void> _load(Uri uri) async {
    // Android does not ask the navigation delegate about loads the app
    // starts itself, so the script for the target site goes in first.
    await _useScriptFor(uri.host);
    await _web.loadRequest(uri);
  }

  /// Registers the ad block script for pages on [host] (it carries that
  /// site's cosmetic rules and scriptlets). Takes effect for documents
  /// created from now on.
  Future<void> _useScriptFor(String host, {bool force = false}) async {
    if (!_userScripts || (!force && host == _scriptHost)) return;
    _scriptHost = host;
    final script = AppScope.of(context).adblock.scriptFor(host);
    try {
      await _web.removeAllUserScripts();
      if (script != null) await _web.addUserScript(WebViewUserScript(source: script, forMainFrameOnly: false));
    } catch (e) {
      debugPrint('DownloadHQ: user script: $e');
    }
  }

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest req) async {
    final adblock = AppScope.of(context).adblock;
    if (adblock.shouldBlock(req.url, isMainFrame: req.isMainFrame, pageUrl: _url.isEmpty ? null : _url)) {
      adblock.countNavigationBlocked();
      return NavigationDecision.prevent;
    }
    if (req.isMainFrame) await _useScriptFor(Uri.tryParse(req.url)?.host ?? '');
    return NavigationDecision.navigate;
  }

  void _onPageStarted(String url) {
    final s = AppScope.of(context);
    final host = Uri.tryParse(url)?.host ?? '';
    final sameSite = host.isNotEmpty && siteOf(host) == siteOf(Uri.tryParse(_url)?.host ?? '');
    s.adblock.newPage(keepNavigations: sameSite);
    if (!_userScripts || host != _scriptHost) {
      // No document-start injection here (or history navigation skipped the
      // delegate): run it now, late but better than not at all, and fix the
      // registration for the next page.
      final script = s.adblock.scriptFor(host);
      if (script != null) _web.runJavaScript('(function(){\n$script\n}).call(globalThis);').catchError((_) {});
      _useScriptFor(host);
    }
    _onUrl(url);
  }

  void _onUrl(String url) {
    if (!mounted) return;
    _url = url;
    if (!_focus.hasFocus) _address.text = url;
    AppScope.of(context).grab.pageChanged(url);
    _refreshHistory();
    setState(() {});
  }

  Future<void> _refreshHistory() async {
    if (!_ready) return;
    final back = await _web.canGoBack();
    final fwd = await _web.canGoForward();
    if (mounted && (back != _canGoBack || fwd != _canGoForward)) {
      setState(() {
        _canGoBack = back;
        _canGoForward = fwd;
      });
    }
  }

  /// Blocking was switched on or off, a site paused, or lists changed: the
  /// open page is reloaded under the new rules.
  bool? _lastEnabled;
  Set<String>? _lastPaused;
  int? _lastRules;
  void _onAdblockChanged() {
    final a = AppScope.of(context).adblock;
    final changed =
        _lastEnabled != null &&
        (_lastEnabled != a.enabled || !setEquals(_lastPaused, a.pausedHosts) || _lastRules != a.networkRuleCount);
    final reload = _lastEnabled != null && (_lastEnabled != a.enabled || !setEquals(_lastPaused, a.pausedHosts));
    _lastEnabled = a.enabled;
    _lastPaused = a.pausedHosts;
    _lastRules = a.networkRuleCount;
    if (!changed || !_ready || _scriptHost == null) return;
    _useScriptFor(_scriptHost!, force: true).then((_) {
      if (reload) _web.reload();
    });
  }

  /// Anything that looks like an address opens; everything else is a search.
  static Uri toUri(String input) {
    final s = input.trim();
    final parsed = Uri.tryParse(s);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) return parsed;
    if (!s.contains(' ') && RegExp(r'^(localhost|[\w-]+(\.[\w-]+)+)(:\d+)?(/.*)?$').hasMatch(s)) {
      return Uri.parse('${s.startsWith('localhost') ? 'http' : 'https'}://$s');
    }
    return Uri.https('duckduckgo.com', '/', {'q': s});
  }

  void _open(String input) {
    if (input.trim().isEmpty || !_ready) return;
    _focus.unfocus();
    _load(toUri(input));
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _adblock.removeListener(_onAdblockChanged);
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 600;
    // System back (Android) walks the page history before leaving the tab.
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _ready) _web.goBack();
      },
      child: Scaffold(
        backgroundColor: t.scaffoldBackgroundColor,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: _canGoBack ? _web.goBack : null,
                      icon: const Icon(PhosphorIconsRegular.arrowLeft),
                    ),
                    if (wide) ...[
                      IconButton(
                        tooltip: 'Forward',
                        onPressed: _canGoForward ? _web.goForward : null,
                        icon: const Icon(PhosphorIconsRegular.arrowRight),
                      ),
                      IconButton(
                        tooltip: 'Reload',
                        onPressed: _ready ? _web.reload : null,
                        icon: const Icon(PhosphorIconsRegular.arrowClockwise),
                      ),
                      IconButton(
                        tooltip: 'Home',
                        onPressed: () => _open(AppScope.of(context).settings.value.home),
                        icon: const Icon(PhosphorIconsRegular.house),
                      ),
                    ],
                    const SizedBox(width: 4),
                    Expanded(child: _addressField(t)),
                    const SizedBox(width: 4),
                    _ShieldButton(onPressed: () => _showShield(context)),
                    _menu(wide),
                  ],
                ),
              ),
              SizedBox(
                height: 2,
                child: _ready && _progress < 100 ? LinearProgressIndicator(value: _progress / 100) : null,
              ),
              Expanded(
                child: !_ready
                    ? const _PageSkeleton()
                    : ValueListenableBuilder(
                        valueListenable: widget.visible,
                        // On Linux the page is a native GTK view painted above
                        // Flutter; it must leave the tree whenever anything
                        // should appear over it. The controller keeps the page.
                        builder: (context, visible, _) => visible || !Platform.isLinux
                            ? WebViewWidget(controller: _web)
                            : ColoredBox(color: t.scaffoldBackgroundColor),
                      ),
              ),
              // Docked below, never overlaid: desktop webviews are native
              // surfaces that paint over any Flutter widget stacked on them.
              const _FindBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressField(ThemeData t) {
    final uri = Uri.tryParse(_url);
    final secure = uri?.scheme == 'https';
    return TextField(
      controller: _address,
      focusNode: _focus,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      autocorrect: false,
      onSubmitted: _open,
      onTap: () => _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length),
      style: t.textTheme.bodyMedium,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search or paste a link',
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 20),
        prefixIcon: Icon(
          _focus.hasFocus
              ? PhosphorIconsRegular.magnifyingGlass
              : (secure ? PhosphorIconsRegular.lockSimple : PhosphorIconsRegular.globeSimple),
          size: 16,
          color: t.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _menu(bool wide) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(PhosphorIconsRegular.dotsThreeVertical),
      onSelected: (v) async {
        final s = AppScope.of(context);
        switch (v) {
          case 'forward':
            _web.goForward();
          case 'reload':
            _web.reload();
          case 'home':
            _open(s.settings.value.home);
          case 'sites':
            final url = await showQuickSites(context);
            if (url != null) _open(url);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: _url));
            if (mounted) showMessage(context, 'Link copied');
          case 'paste':
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final text = d?.text?.trim() ?? '';
            if (text.isEmpty) {
              if (mounted) showMessage(context, 'The clipboard is empty');
            } else {
              _open(text);
            }
          case 'sethome':
            s.settings.update((x) => x.copyWith(homePage: _url));
            showMessage(context, 'Home page set');
        }
      },
      itemBuilder: (_) => [
        if (!wide) ...[
          PopupMenuItem(value: 'forward', enabled: _canGoForward, child: const Text('Forward')),
          const PopupMenuItem(value: 'reload', child: Text('Reload')),
          const PopupMenuItem(value: 'home', child: Text('Home')),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: 'sites', child: Text('Quick sites')),
        const PopupMenuItem(value: 'paste', child: Text('Open copied link')),
        PopupMenuItem(value: 'copy', enabled: _url.startsWith('http'), child: const Text('Copy link')),
        PopupMenuItem(value: 'sethome', enabled: _url.startsWith('http'), child: const Text('Use as home page')),
      ],
    );
  }

  Future<void> _showShield(BuildContext context) => showModalBottomSheet(
    context: context,
    builder: (_) => _ShieldSheet(host: Uri.tryParse(_url)?.host ?? ''),
  );
}

/// Grey blocks in the shape of a page while the browser starts.
class _PageSkeleton extends StatelessWidget {
  const _PageSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHigh;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(Tokens.radiusInput)),
    );
    return Padding(
      padding: const EdgeInsets.all(Tokens.gutter),
      child: LayoutBuilder(
        builder: (context, box) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(box.maxWidth, box.maxWidth * 9 / 16 > 220 ? 220 : box.maxWidth * 9 / 16),
            bar(box.maxWidth * 0.8, 16),
            bar(box.maxWidth * 0.5, 12),
          ],
        ),
      ),
    );
  }
}

/// Shield in the toolbar with the number blocked on this page.
class _ShieldButton extends StatelessWidget {
  const _ShieldButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final a = AppScope.of(context).adblock;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final n = a.pageBlocked;
        final icon = Icon(
          a.enabled ? PhosphorIconsFill.shieldCheck : PhosphorIconsRegular.shieldSlash,
          color: a.enabled ? cs.primary : cs.onSurfaceVariant,
        );
        return IconButton(
          tooltip: a.enabled ? 'Ad blocker: $n blocked on this page' : 'Ad blocker is off',
          onPressed: onPressed,
          icon: n == 0 || !a.enabled
              ? icon
              : Badge(
                  label: Text(n > 99 ? '99+' : '$n'),
                  backgroundColor: cs.primary,
                  textColor: cs.onPrimary,
                  child: icon,
                ),
        );
      },
    );
  }
}

class _ShieldSheet extends StatelessWidget {
  const _ShieldSheet({required this.host});
  final String host;

  @override
  Widget build(BuildContext context) {
    final a = AppScope.of(context).adblock;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final paused = a.isPaused(host);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ad blocker', style: t.textTheme.titleLarge),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${a.enabled && !paused ? a.pageBlocked : 0}',
                      style: t.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('blocked on this page', style: t.textTheme.bodyMedium),
                    ),
                  ],
                ),
                Text('${a.totalBlocked} blocked since install', style: t.textTheme.bodySmall),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Block ads and trackers'),
                  subtitle: Text(
                    a.lastUpdated == null
                        ? 'Built-in list for now. Full filter lists are downloading.'
                        : '${a.networkRuleCount} network rules from ${a.enabledListCount} filter lists',
                  ),
                  value: a.enabled,
                  onChanged: a.setEnabled,
                ),
                if (host.isNotEmpty)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Block on ${siteOf(host)}'),
                    subtitle: const Text('Turn off if this site breaks or refuses to load'),
                    value: a.enabled && !paused,
                    onChanged: a.enabled ? (on) => a.setPaused(host, !on) : null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<String?> showQuickSites(BuildContext context) => showModalBottomSheet<String>(
  context: context,
  builder: (c) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Text('Quick sites', style: Theme.of(c).textTheme.titleLarge),
        ),
        for (final (name, url, icon) in _BrowseScreenState.quickSites)
          ListTile(
            leading: Icon(icon),
            title: Text(name),
            subtitle: Text(Uri.parse(url).host),
            onTap: () => Navigator.pop(c, url),
          ),
      ],
    ),
  ),
);

/// Status bar under the page: what yt-dlp made of it, and the way to save it.
class _FindBar extends StatelessWidget {
  const _FindBar();

  @override
  Widget build(BuildContext context) {
    final grab = AppScope.of(context).grab;
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: grab,
      builder: (context, _) {
        final r = grab.result;
        final (Widget lead, String title, String? sub, Widget? action) = switch (grab.state) {
          ProbeState.idle => (
            Icon(PhosphorIconsRegular.magnifyingGlass, color: cs.onSurfaceVariant),
            'Open a video, song or playlist to save it',
            null,
            null,
          ),
          ProbeState.looking => (const ProgressRing(size: 22), 'Looking for media on this page', null, null),
          ProbeState.none => (
            Icon(PhosphorIconsRegular.prohibit, color: cs.onSurfaceVariant),
            grab.reason ?? 'Nothing found',
            null,
            TextButton(onPressed: grab.probeAgain, child: const Text('Try again')),
          ),
          ProbeState.found => (
            Icon(PhosphorIconsFill.checkCircle, color: cs.primary),
            r!.entries.length == 1 ? r.entries.first.title : '${r.entries.length} items: ${r.title}',
            r.entries.length == 1
                ? (r.entries.first.heights.isEmpty ? 'Audio' : 'Video up to ${r.entries.first.heights.last}p')
                : 'Pick which to save',
            FilledButton.icon(
              onPressed: () => showGrabSheet(context),
              icon: const Icon(PhosphorIconsBold.downloadSimple, size: 18),
              label: const Text('Save'),
            ),
          ),
        };
        return Material(
          color: cs.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: cs.outline)),
              ),
              padding: const EdgeInsets.fromLTRB(Tokens.gutter, 10, 12, 10),
              constraints: const BoxConstraints(minHeight: 60),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Row(
                  key: ValueKey(grab.state),
                  children: [
                    SizedBox.square(dimension: 24, child: Center(child: lead)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                          if (sub != null) Text(sub, style: t.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    if (action != null) ...[const SizedBox(width: 12), action],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
