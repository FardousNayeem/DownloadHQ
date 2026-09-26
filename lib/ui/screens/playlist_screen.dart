import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../services/download_queue.dart';
import '../format.dart';
import '../widgets/common.dart';

enum _Filter {
  all('All'),
  fresh('New'),
  notSaved('Not saved'),
  saved('Saved'),
  skipped('Skipped'),
  gone('Removed on YouTube');

  const _Filter(this.label);
  final String label;

  bool test(Entry e) => switch (this) {
    all => !e.ignored,
    fresh => e.isNew && e.isPending,
    notSaved => e.isPending,
    saved => e.isDownloaded,
    skipped => e.ignored,
    gone => e.removedFromSource,
  };
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlistId});
  final String playlistId;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  _Filter? _filter;
  final Set<String> _selected = {};

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.queue, s.playback]),
      builder: (context, _) {
        final p = s.library.byId(widget.playlistId);
        if (p == null) return const Scaffold(body: SizedBox.shrink());
        // Open on "New" when there is something new to look at.
        final filter = _filter ??= p.newCount > 0 ? _Filter.fresh : _Filter.all;
        final visible = p.entries.where(filter.test).toList();
        _selected.removeWhere((id) => !(p.entry(id)?.isPending ?? false));
        final selectable = visible.where((e) => e.isPending && s.queue.jobFor(p.id, e.id) == null).toList();

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                title: Text(p.title, overflow: TextOverflow.ellipsis),
                actions: [
                  if (p.downloadedCount > 0)
                    IconButton(
                      tooltip: 'Play saved',
                      icon: const Icon(PhosphorIconsFill.play),
                      onPressed: () => s.playback.playAll(p.entries),
                    ),
                  if (!p.isWeb)
                    IconButton(
                      tooltip: 'Check for new videos',
                      onPressed: s.library.isSyncing(p.id) ? null : () => s.library.sync(p.id),
                      icon: s.library.isSyncing(p.id)
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(PhosphorIconsRegular.arrowsClockwise),
                    ),
                  IconButton(
                    tooltip: p.isWeb ? 'Options' : 'Playlist options',
                    icon: const Icon(PhosphorIconsRegular.slidersHorizontal),
                    onPressed: () => _showOptions(context, p),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              SliverToBoxAdapter(child: _Header(playlist: p)),
              if (p.newCount > 0 && filter == _Filter.fresh)
                SliverToBoxAdapter(
                  child: _NewBanner(
                    count: p.newCount,
                    onSelectAll: () => setState(() => _selected.addAll(selectable.map((e) => e.id))),
                    onDismiss: () {
                      s.library.acknowledgeNew(p.id);
                      setState(() => _filter = _Filter.all);
                    },
                  ),
                ),
              SliverToBoxAdapter(
                child: _FilterBar(
                  playlist: p,
                  current: filter,
                  onChanged: (f) => setState(() => _filter = f),
                  onSelectAll: selectable.isEmpty
                      ? null
                      : () => setState(() {
                          final ids = selectable.map((e) => e.id);
                          _selected.containsAll(ids) ? _selected.removeAll(ids) : _selected.addAll(ids);
                        }),
                  allSelected: selectable.isNotEmpty && _selected.containsAll(selectable.map((e) => e.id)),
                ),
              ),
              if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: PhosphorIconsRegular.checks,
                    title: 'Nothing here',
                    body: switch (filter) {
                      _Filter.fresh => 'No new videos since the last check.',
                      _Filter.notSaved => 'Everything in this playlist is saved.',
                      _Filter.saved => 'Pick videos from the list and download them to see them here.',
                      _ => 'No videos match this filter.',
                    },
                  ),
                )
              else
                SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final e = visible[i];
                    return _EntryRow(
                      playlist: p,
                      entry: e,
                      job: s.queue.jobFor(p.id, e.id),
                      selected: _selected.contains(e.id),
                      onToggle: () => _toggle(e.id),
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
          bottomNavigationBar: _selected.isEmpty
              ? null
              : _SelectionBar(
                  count: _selected.length,
                  onClear: () => setState(_selected.clear),
                  onSkip: () {
                    s.library.setIgnored(p.id, {..._selected}, true);
                    setState(_selected.clear);
                  },
                  onDownload: () {
                    s.queue.enqueue(p.id, [..._selected]);
                    showMessage(context, 'Queued ${_selected.length} for download');
                    setState(_selected.clear);
                  },
                ),
        );
      },
    );
  }

  Future<void> _showOptions(BuildContext context, Playlist p) => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _OptionsSheet(playlistId: p.id),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = playlist;
    if (p.isWeb) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 12),
        child: Text('${p.downloadedCount} saved from pages you browsed. Newest first.', style: t.textTheme.bodySmall),
      );
    }
    final mode = p.prefs.mode == MediaMode.audio ? 'Audio' : 'Video up to ${p.prefs.maxHeight}p';
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.channel != null) Text(p.channel!, style: t.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '${p.downloadedCount} saved, ${p.pendingCount} not saved. $mode. Checked ${formatAgo(p.lastSynced)}.',
            style: t.textTheme.bodySmall,
          ),
          if (p.lastSyncError != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last check failed: ${p.lastSyncError}',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _NewBanner extends StatelessWidget {
  const _NewBanner({required this.count, required this.onSelectAll, required this.onDismiss});
  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 12),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Tokens.radiusSurface),
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsFill.sparkle, color: cs.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(count == 1 ? '1 video added since last check' : '$count videos added since last check')),
          TextButton(onPressed: onSelectAll, child: const Text('Select all')),
          TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.playlist,
    required this.current,
    required this.onChanged,
    required this.onSelectAll,
    required this.allSelected,
  });

  final Playlist playlist;
  final _Filter current;
  final ValueChanged<_Filter> onChanged;
  final VoidCallback? onSelectAll;
  final bool allSelected;

  @override
  Widget build(BuildContext context) {
    final counts = {for (final f in _Filter.values) f: playlist.entries.where(f.test).length};
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
              child: Row(
                children: [
                  for (final f in _Filter.values)
                    if (f == _Filter.all || counts[f]! > 0 || f == current)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${f.label}  ${counts[f]}'),
                          selected: f == current,
                          showCheckmark: false,
                          onSelected: (_) => onChanged(f),
                        ),
                      ),
                ],
              ),
            ),
          ),
          if (onSelectAll != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                tooltip: allSelected ? 'Clear selection' : 'Select all shown',
                onPressed: onSelectAll,
                icon: Icon(allSelected ? PhosphorIconsFill.checkSquare : PhosphorIconsRegular.checkSquare),
              ),
            ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.playlist,
    required this.entry,
    required this.job,
    required this.selected,
    required this.onToggle,
  });

  final Playlist playlist;
  final Entry entry;
  final DownloadJob? job;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final e = entry;
    final dim = e.unavailable && !e.isDownloaded;
    final nowPlaying = s.playback.current?.id == e.id;

    VoidCallback? onTap;
    if (e.isDownloaded) {
      onTap = () => s.playback.playAll(playlist.entries, start: e);
    } else if (e.ignored) {
      onTap = () => s.library.setIgnored(playlist.id, {e.id}, false);
    } else if (e.isPending && job == null) {
      onTap = onToggle;
    }

    final meta = [if (e.channel != null) e.channel!, if (e.duration != null) formatDuration(e.duration)].join('   ');

    return Material(
      color: selected ? t.colorScheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: e.isDownloaded ? () => _confirmDelete(context) : null,
        onSecondaryTap: e.isDownloaded ? () => _confirmDelete(context) : null,
        child: Opacity(
          opacity: dim ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 8),
            child: Row(
              children: [
                EntryThumb(entry: e),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (e.isNew && e.isPending) ...[const NewTag(), const SizedBox(width: 6)],
                          if (nowPlaying) ...[
                            Icon(PhosphorIconsFill.speakerHigh, size: 16, color: t.colorScheme.primary),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              e.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.bodyLarge?.copyWith(color: nowPlaying ? t.colorScheme.primary : null),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _statusLine(e, job) ?? meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(
                          color:
                              (job?.state == JobState.failed || (job == null && e.lastError != null && !e.isDownloaded))
                              ? t.colorScheme.error
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _Trailing(
                  playlist: playlist,
                  entry: e,
                  job: job,
                  selected: selected,
                  onToggle: onToggle,
                  onDelete: () => _confirmDelete(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _statusLine(Entry e, DownloadJob? job) {
    if (job != null) {
      return switch (job.state) {
        JobState.queued => 'Waiting',
        JobState.failed => job.error ?? 'Failed',
        JobState.running => [
          if (job.progress?.fraction != null) '${(job.progress!.fraction! * 100).round()}%',
          if (job.progress?.speedBps != null) formatSpeed(job.progress!.speedBps),
          if (job.progress?.eta != null) '${formatDuration(job.progress!.eta)} left',
        ].join('   ').ifEmpty('Starting'),
      };
    }
    if (e.unavailable && !e.isDownloaded) return 'Private or deleted on YouTube';
    if (e.removedFromSource) return 'Removed from the playlist, kept here';
    if (e.ignored) return 'Skipped. Tap to bring back';
    if (e.lastError != null && !e.isDownloaded) return 'Failed: ${e.lastError}';
    return null;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final s = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text('The file for "${entry.title}" is removed from this device. You can download it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await s.playback.forget(entry.id);
    await s.library.deleteDownload(playlist.id, entry.id);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.playlist,
    required this.entry,
    required this.job,
    required this.selected,
    required this.onToggle,
    required this.onDelete,
  });

  final VoidCallback onDelete;

  final Playlist playlist;
  final Entry entry;
  final DownloadJob? job;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final j = job;
    if (j != null) {
      return switch (j.state) {
        JobState.failed => IconButton(
          tooltip: 'Retry',
          icon: Icon(PhosphorIconsRegular.arrowCounterClockwise, color: cs.error),
          onPressed: () => s.queue.retry(j),
        ),
        _ => IconButton(
          tooltip: 'Cancel',
          onPressed: () => s.queue.cancel(j),
          icon: ProgressRing(
            value: j.state == JobState.running ? j.progress?.fraction : null,
            size: 36,
            center: const Icon(PhosphorIconsBold.x, size: 12),
          ),
        ),
      };
    }
    if (entry.isDownloaded) {
      // Saved: the check doubles as the menu, so delete is findable on
      // desktop too (long-press and right-click also work).
      return PopupMenuButton<String>(
        tooltip: 'Saved. More options',
        icon: Icon(PhosphorIconsFill.checkCircle, color: cs.primary, size: 22),
        onSelected: (v) => v == 'play' ? s.playback.playAll(playlist.entries, start: entry) : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'play', child: Text('Play')),
          PopupMenuItem(value: 'delete', child: Text('Delete download')),
        ],
      );
    }
    if (entry.isPending) {
      return Checkbox(value: selected, onChanged: (_) => onToggle());
    }
    return const SizedBox(width: 48);
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.onClear, required this.onSkip, required this.onDownload});
  final int count;
  final VoidCallback onClear;
  final VoidCallback onSkip;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Tokens.radiusSurface),
        ),
        child: Row(
          children: [
            IconButton(tooltip: 'Clear selection', onPressed: onClear, icon: const Icon(PhosphorIconsRegular.x)),
            Text('$count selected'),
            const Spacer(),
            TextButton(onPressed: onSkip, child: const Text('Skip')),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(PhosphorIconsBold.downloadSimple, size: 18),
              label: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionsSheet extends StatelessWidget {
  const _OptionsSheet({required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final p = s.library.byId(playlistId);
        if (p == null) return const SizedBox.shrink();
        final prefs = p.prefs;
        void set(DownloadPrefs n) => s.library.setPrefs(p.id, n);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!p.isWeb) ...[
                  Text('Download options', style: t.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('Applies to downloads started from now on.', style: t.textTheme.bodySmall),
                  const SizedBox(height: 20),
                  Text('Save as', style: t.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<MediaMode>(
                    segments: const [
                      ButtonSegment(
                        value: MediaMode.audio,
                        label: Text('Audio'),
                        icon: Icon(PhosphorIconsRegular.headphones),
                      ),
                      ButtonSegment(
                        value: MediaMode.video,
                        label: Text('Video'),
                        icon: Icon(PhosphorIconsRegular.filmStrip),
                      ),
                    ],
                    selected: {prefs.mode},
                    onSelectionChanged: (v) => set(prefs.copyWith(mode: v.first)),
                  ),
                  if (prefs.mode == MediaMode.video) ...[
                    const SizedBox(height: 20),
                    Text('Highest quality', style: t.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final h in const [360, 480, 720, 1080])
                          ChoiceChip(
                            label: Text('${h}p'),
                            selected: prefs.maxHeight == h,
                            showCheckmark: false,
                            onSelected: (_) => set(prefs.copyWith(maxHeight: h)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Download new videos automatically'),
                    subtitle: const Text('Otherwise they wait in "New" for you to pick.'),
                    value: prefs.autoDownloadNew,
                    onChanged: (v) => set(prefs.copyWith(autoDownloadNew: v)),
                  ),
                  const Divider(height: 24),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(PhosphorIconsRegular.trash, color: t.colorScheme.error),
                  title: Text(
                    p.isWeb ? 'Clear this list' : 'Remove playlist',
                    style: TextStyle(color: t.colorScheme.error),
                  ),
                  onTap: () => _remove(context, p),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _remove(BuildContext context, Playlist p) async {
    final s = AppScope.of(context);
    final nav = Navigator.of(context);
    final choice = await showDialog<bool?>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(p.isWeb ? 'Clear "${p.title}"?' : 'Remove playlist?'),
        content: Text(
          p.isWeb
              ? 'Everything grabbed while browsing leaves the list. ${p.downloadedCount} saved files can stay '
                    'on disk or be deleted.'
              : 'DownloadHQ stops tracking "${p.title}". ${p.downloadedCount} saved files can stay on disk or be '
                    'deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep files')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete files')),
        ],
      ),
    );
    if (choice == null) return;
    s.queue.cancelPlaylist(p.id);
    if (choice) {
      for (final e in p.entries) {
        await s.playback.forget(e.id);
      }
    }
    await s.library.remove(p.id, deleteFiles: choice);
    nav
      ..pop()
      ..pop();
  }
}
