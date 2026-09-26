import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../format.dart';
import '../widgets/common.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.tools]),
      builder: (context, _) {
        final lists = s.library.playlists;
        final toolsMissing = s.tools.status != null && !s.tools.ready;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [
              if (lists.isNotEmpty)
                IconButton(
                  tooltip: 'Check all for new videos',
                  onPressed: s.library.anySyncing ? null : s.library.syncAll,
                  icon: s.library.anySyncing
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(PhosphorIconsRegular.arrowsClockwise),
                ),
              const SizedBox(width: 8),
            ],
          ),
          floatingActionButton: lists.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => showAddPlaylistSheet(context),
                  shape: const StadiumBorder(),
                  icon: const Icon(PhosphorIconsBold.plus),
                  label: const Text('Add playlist'),
                ),
          body: Column(
            children: [
              if (toolsMissing) _ToolsBanner(onOpenSettings: onOpenSettings),
              Expanded(
                child: lists.isEmpty
                    ? EmptyState(
                        icon: PhosphorIconsRegular.playlist,
                        title: 'Keep a playlist offline',
                        body:
                            'Paste a YouTube playlist link. DownloadHQ lists every video, lets you pick what '
                            'to save, and flags new additions each time it checks.',
                        action: FilledButton.icon(
                          onPressed: () => showAddPlaylistSheet(context),
                          icon: const Icon(PhosphorIconsBold.plus, size: 18),
                          label: const Text('Add playlist'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: s.library.syncAll,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(0, 4, 0, 96),
                          itemCount: lists.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 4),
                          itemBuilder: (context, i) => _PlaylistRow(playlist: lists[i]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ToolsBanner extends StatelessWidget {
  const _ToolsBanner({required this.onOpenSettings});
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Tokens.radiusSurface),
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsRegular.wrench, color: cs.primary),
          const SizedBox(width: 12),
          const Expanded(child: Text('Some tools are missing. Downloads will fail until they are set up.')),
          TextButton(onPressed: onOpenSettings, child: const Text('Set up')),
        ],
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final p = playlist;
    final cover = p.entries.where((e) => !e.unavailable).firstOrNull;
    final syncing = s.library.isSyncing(p.id);
    final visible = p.entries.where((e) => !e.unavailable).length;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: p.id))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 10),
        child: Row(
          children: [
            EntryThumb(entry: cover, width: 112, radius: 12),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('${p.downloadedCount} of $visible saved', style: t.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(
                    p.isWeb
                        ? 'Grabbed while browsing'
                        : syncing
                        ? 'Checking now'
                        : p.lastSyncError != null
                        ? 'Last check failed'
                        : 'Checked ${formatAgo(p.lastSynced)}',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: p.lastSyncError != null && !syncing ? t.colorScheme.error : null,
                    ),
                  ),
                ],
              ),
            ),
            if (p.newCount > 0) CountBadge(p.newCount, label: 'new'),
          ],
        ),
      ),
    );
  }
}

Future<void> showAddPlaylistSheet(BuildContext context) =>
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => const _AddPlaylistSheet());

class _AddPlaylistSheet extends StatefulWidget {
  const _AddPlaylistSheet();
  @override
  State<_AddPlaylistSheet> createState() => _AddPlaylistSheetState();
}

class _AddPlaylistSheetState extends State<_AddPlaylistSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final s = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await s.library.add(_ctrl.text);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: p.id)));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add playlist', style: t.textTheme.titleLarge),
          const SizedBox(height: 16),
          Text('Playlist link', style: t.textTheme.labelLarge),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'https://www.youtube.com/playlist?list=...',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Public and unlisted playlists work. Private ones need you signed in, which DownloadHQ does not do.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}
