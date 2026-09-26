import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../data/repositories.dart';
import '../../domain/models.dart';
import '../../engine/engine.dart';
import '../../services/adblock_service.dart';
import '../format.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.tools, s.adblock]),
      builder: (context, _) {
        final v = s.settings.value;
        final tools = s.tools;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              const _Section('Ad blocker'),
              const _AdblockSettings(),
              const _Section('Browser'),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.house),
                title: const Text('Home page'),
                subtitle: Text(v.home, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _editHomePage(context, v),
              ),
              const _Section('Tools'),
              if (tools.status == null)
                const Padding(padding: EdgeInsets.all(Tokens.gutter), child: LinearProgressIndicator())
              else
                for (final tool in tools.status!.tools) _ToolRow(tool: tool),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (tools.canInstall && tools.missing.length > 1)
                      FilledButton.icon(
                        onPressed: tools.missing.every(tools.isQueued) ? null : tools.installMissing,
                        icon: const Icon(PhosphorIconsBold.downloadSimple, size: 18),
                        label: Text('Install missing (${tools.missing.length})'),
                      ),
                    OutlinedButton.icon(
                      onPressed: tools.busy ? null : tools.updateYtDlp,
                      icon: const Icon(PhosphorIconsRegular.arrowCircleUp, size: 18),
                      label: const Text('Update yt-dlp'),
                    ),
                    OutlinedButton.icon(
                      onPressed: tools.busy ? null : tools.refresh,
                      icon: const Icon(PhosphorIconsRegular.arrowsClockwise, size: 18),
                      label: const Text('Check again'),
                    ),
                  ],
                ),
              ),
              if (tools.message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 0),
                  child: Text(tools.message!, style: t.textTheme.bodySmall),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 0),
                child: Text(
                  'YouTube changes often. When downloads start failing, update yt-dlp first.',
                  style: t.textTheme.bodySmall,
                ),
              ),
              const _Section('Downloads'),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.folder),
                title: const Text('Save to'),
                subtitle: Text(v.downloadDir, maxLines: 2, overflow: TextOverflow.ellipsis),
                // Android keeps files in app storage: no permission prompts, and
                // the in-app player is the way to listen.
                onTap: Platform.isAndroid
                    ? null
                    : () async {
                        final dir = await getDirectoryPath(initialDirectory: v.downloadDir);
                        if (dir != null) s.settings.update((x) => x.copyWith(downloadDir: dir));
                      },
              ),
              _Stepper(
                icon: PhosphorIconsRegular.stack,
                title: 'Downloads at once',
                value: v.parallelDownloads,
                options: const [1, 2, 3, 4],
                label: (n) => '$n',
                onChanged: (n) => s.settings.update((x) => x.copyWith(parallelDownloads: n)),
              ),
              _Stepper(
                icon: PhosphorIconsRegular.clockCountdown,
                title: 'Check playlists for new videos',
                value: v.checkEveryHours,
                options: const [0, 1, 6, 24],
                label: (n) => n == 0 ? 'On launch' : 'Every ${n}h',
                onChanged: (n) => s.settings.update((x) => x.copyWith(checkEveryHours: n)),
              ),
              _Stepper(
                icon: PhosphorIconsRegular.scissors,
                title: 'Sponsor segments in YouTube videos',
                value: v.sponsorBlock.index,
                options: [for (final m in SponsorBlock.values) m.index],
                label: (i) => SponsorBlock.values[i].label,
                onChanged: (i) => s.settings.update((x) => x.copyWith(sponsorBlock: SponsorBlock.values[i])),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 4),
                child: Text(
                  'Uses SponsorBlock community data. Cutting out needs ffmpeg.',
                  style: t.textTheme.bodySmall,
                ),
              ),
              SwitchListTile(
                secondary: const Icon(PhosphorIconsRegular.subtitles),
                title: const Text('Embed subtitles in videos'),
                subtitle: const Text('English subtitles from the uploader, when there are any'),
                value: v.embedSubtitles,
                onChanged: (on) => s.settings.update((x) => x.copyWith(embedSubtitles: on)),
              ),
              const _Section('Appearance'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
                // Full-width segments look stretched on a desktop window.
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, label: Text('System')),
                        ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                        ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                      ],
                      selected: {v.themeMode},
                      onSelectionChanged: (m) => s.settings.update((x) => x.copyWith(themeMode: m.first)),
                    ),
                  ),
                ),
              ),
              const _Section('About'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
                child: Text(
                  'DownloadHQ browses without ads, saves media from the pages you open and keeps YouTube '
                  'playlists on this device, using yt-dlp and filter lists from uBlock Origin, EasyList and '
                  'Peter Lowe. Download only what you have the right to keep.',
                  style: t.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _editHomePage(BuildContext context, AppSettings v) async {
  final s = AppScope.of(context);
  final ctrl = TextEditingController(text: v.home);
  final result = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Home page'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: AppSettings.defaultHomePage),
        onSubmitted: (x) => Navigator.pop(c, x),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Reset')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Save')),
      ],
    ),
  );
  ctrl.dispose();
  if (result == null) return;
  final text = result.trim();
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  s.settings.update(
    (x) => x.copyWith(homePage: text.isEmpty || uri == null || uri.host.isEmpty ? null : uri.toString()),
  );
}

class _AdblockSettings extends StatelessWidget {
  const _AdblockSettings();

  @override
  Widget build(BuildContext context) {
    final a = AppScope.of(context).adblock;
    final t = Theme.of(context);
    final paused = a.pausedHosts.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(PhosphorIconsRegular.shieldCheck),
          title: const Text('Block ads and trackers'),
          subtitle: Text(
            '${a.totalBlocked} blocked so far. ${a.networkRuleCount} network and ${a.siteRuleCount} site rules.',
          ),
          value: a.enabled,
          onChanged: a.setEnabled,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 4),
          child: Text('Filter lists', style: t.textTheme.labelLarge),
        ),
        for (final l in filterLists)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l.name),
            subtitle: Text(
              a.isListOn(l.id)
                  ? (a.listUpdated(l.id) == null ? 'Not downloaded yet' : 'Updated ${formatAgo(a.listUpdated(l.id))}')
                  : 'Off',
            ),
            value: a.isListOn(l.id),
            onChanged: a.updating ? null : (on) => a.setListOn(l.id, on ?? false),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 0),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: a.updating ? null : () => a.updateLists(force: true),
                icon: a.updating
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(PhosphorIconsRegular.arrowsClockwise, size: 18),
                label: Text(a.updating ? 'Updating' : 'Update lists now'),
              ),
            ],
          ),
        ),
        if (a.message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 0),
            child: Text(a.message!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 0),
          child: Text(
            'Lists update every ${AdblockService.maxAge.inDays} days. Pause a site from the shield in the browser.',
            style: t.textTheme.bodySmall,
          ),
        ),
        if (paused.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 16, Tokens.gutter, 4),
            child: Text('Paused on', style: t.textTheme.labelLarge),
          ),
          for (final h in paused)
            ListTile(
              dense: true,
              title: Text(h),
              trailing: IconButton(
                tooltip: 'Block ads here again',
                icon: const Icon(PhosphorIconsRegular.x),
                onPressed: () => a.setPaused(h, false),
              ),
            ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Tokens.gutter, 28, Tokens.gutter, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});
  final ToolStatus tool;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final busy = s.tools.busyTool == tool.name;
    final waiting = s.tools.isWaiting(tool.name);
    final Widget trailing;
    if (busy) {
      trailing = ProgressRing(value: s.tools.busyProgress, size: 52);
    } else if (waiting) {
      trailing = Text('Waiting', style: Theme.of(context).textTheme.bodySmall);
    } else if (!tool.found && s.tools.canInstall) {
      trailing = FilledButton(onPressed: () => s.tools.install(tool.name), child: const Text('Install'));
    } else {
      trailing = Icon(
        tool.found ? PhosphorIconsFill.checkCircle : PhosphorIconsRegular.warningCircle,
        color: tool.found ? cs.primary : (tool.required ? cs.error : cs.onSurfaceVariant),
      );
    }
    final subtitle = busy ? s.tools.busyStage : (tool.found ? (tool.path ?? tool.purpose) : tool.purpose);
    return ListTile(
      title: Text(tool.version == null ? tool.name : '${tool.name}  ${tool.version}'),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final int value;
  final List<int> options;
  final String Function(int) label;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon), const SizedBox(width: 16), Text(title)]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(label(o)),
                  selected: o == value,
                  showCheckmark: false,
                  onSelected: (_) => onChanged(o),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
