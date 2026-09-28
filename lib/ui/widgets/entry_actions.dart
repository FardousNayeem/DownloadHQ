import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../services/file_actions.dart';
import '../format.dart';
import 'common.dart';

/// Everything you can do with one entry, from a long-press, right-click or
/// its menu button. Saved files get the file actions; the rest get what
/// makes sense before a download.
Future<void> showEntryActions(BuildContext context, {required String playlistId, required String entryId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => _EntryActionsSheet(playlistId: playlistId, entryId: entryId, host: context),
  );
}

class _EntryActionsSheet extends StatelessWidget {
  const _EntryActionsSheet({required this.playlistId, required this.entryId, required this.host});

  final String playlistId;
  final String entryId;

  /// The screen that opened the sheet; dialogs and messages go there after
  /// the sheet closes.
  final BuildContext host;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final pl = s.library.byId(playlistId);
    final e = pl?.entry(entryId);
    if (pl == null || e == null) return const SizedBox.shrink();
    final path = e.filePath;
    final saved = e.isDownloaded && path != null;
    final pb = s.playback;
    final isCurrent = pb.current?.id == e.id;

    void run(Future<void> Function() action) {
      Navigator.pop(context);
      action().catchError((Object err) {
        if (host.mounted) showMessage(host, _plain(err));
      });
    }

    final tiles = <Widget>[
      if (saved) ...[
        _Action(
          icon: PhosphorIconsRegular.play,
          label: isCurrent ? 'Play from the start' : 'Play',
          onTap: () => run(() => pb.playAll(pl.entries, start: e)),
        ),
        if (pb.current != null && !isCurrent)
          _Action(
            icon: PhosphorIconsRegular.queue,
            label: 'Play next',
            onTap: () => run(() async {
              pb.playNext(e);
              if (host.mounted) showMessage(host, 'Plays after the current track');
            }),
          ),
        _Action(icon: PhosphorIconsRegular.pencilSimple, label: 'Rename', onTap: () => run(() => _rename(host, pl, e))),
        if (FileActions.canReveal)
          _Action(
            icon: PhosphorIconsRegular.folderOpen,
            label: 'Show in folder',
            onTap: () => run(() => FileActions.reveal(path)),
          ),
        _Action(
          icon: PhosphorIconsRegular.arrowSquareOut,
          label: Platform.isAndroid ? 'Open with' : 'Open in another player',
          onTap: () => run(() => FileActions.openExternally(path)),
        ),
        if (FileActions.canShare)
          _Action(
            icon: PhosphorIconsRegular.shareNetwork,
            label: 'Share file',
            onTap: () => run(() => FileActions.share(path, title: e.title)),
          ),
      ],
      _Action(
        icon: PhosphorIconsRegular.link,
        label: 'Copy link',
        onTap: () => run(() async {
          await Clipboard.setData(ClipboardData(text: e.downloadUrl));
          if (host.mounted) showMessage(host, 'Link copied');
        }),
      ),
      if (saved && !Platform.isAndroid)
        _Action(
          icon: PhosphorIconsRegular.copy,
          label: 'Copy file path',
          onTap: () => run(() async {
            await Clipboard.setData(ClipboardData(text: path));
            if (host.mounted) showMessage(host, 'Path copied');
          }),
        ),
      if (e.isPending)
        _Action(
          icon: PhosphorIconsRegular.downloadSimple,
          label: 'Download',
          onTap: () => run(() async {
            final n = s.queue.enqueue(pl.id, [e.id]);
            if (host.mounted) showMessage(host, n > 0 ? 'Queued for download' : 'Already downloading');
          }),
        ),
      if (!e.isDownloaded && !pl.isWeb)
        _Action(
          icon: e.ignored ? PhosphorIconsRegular.eye : PhosphorIconsRegular.eyeSlash,
          label: e.ignored ? 'Bring back' : 'Skip this video',
          onTap: () => run(() async => s.library.setIgnored(pl.id, {e.id}, !e.ignored)),
        ),
      if (saved)
        _Action(
          icon: PhosphorIconsRegular.trash,
          label: 'Delete download',
          danger: true,
          onTap: () => run(() => confirmDeleteDownload(host, pl.id, e)),
        ),
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: ShapeDecoration(color: t.colorScheme.outline, shape: const StadiumBorder()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 16, Tokens.gutter, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EntryThumb(entry: e, width: 96),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          _FileFacts(entry: e),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              const SizedBox(height: 4),
              ...tiles,
            ],
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.danger = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: 1),
      leading: Icon(icon, size: 22, color: color),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: onTap,
    );
  }
}

/// Channel, length, and for saved files the format and size on disk.
class _FileFacts extends StatelessWidget {
  const _FileFacts({required this.entry});
  final Entry entry;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final e = entry;
    final base = [if (e.channel != null) e.channel!, if (e.duration != null) formatDuration(e.duration)];
    final path = e.filePath;
    if (path == null) return Text(base.join('   '), style: style, maxLines: 2);
    return FutureBuilder<int>(
      future: File(path).length().catchError((_) => -1),
      builder: (context, snap) {
        final size = snap.data;
        final parts = [
          ...base,
          p.extension(path).replaceFirst('.', '').toUpperCase(),
          if (size != null && size >= 0) formatBytes(size),
          if (size == -1) 'File missing',
        ];
        return Text(parts.join('   '), style: style, maxLines: 2);
      },
    );
  }
}

Future<void> _rename(BuildContext context, Playlist pl, Entry e) async {
  final s = AppScope.of(context);
  final title = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(initial: e.title),
  );
  if (title == null || title.trim().isEmpty || title.trim() == e.title) return;
  final pb = s.playback;
  // Windows will not rename a file the player holds open.
  final wasCurrent = pb.current?.id == e.id;
  if (wasCurrent && Platform.isWindows) await pb.stop();
  final updated = await s.library.rename(pl.id, e.id, title);
  if (updated != null) pb.refresh(updated);
  if (context.mounted) showMessage(context, 'Renamed');
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    if (_c.text.trim().isEmpty) return;
    Navigator.pop(context, _c.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Title', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            TextField(
              controller: _c,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              'The file on disk is renamed to match. Checking the playlist again keeps this title.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _c.text.trim().isEmpty ? null : _submit, child: const Text('Rename')),
      ],
    );
  }
}

/// Asks, then deletes the file of a saved entry.
Future<void> confirmDeleteDownload(BuildContext context, String playlistId, Entry entry) async {
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
  await s.library.deleteDownload(playlistId, entry.id);
}

String _plain(Object err) => switch (err) {
  FileSystemException(:final message, :final osError) => osError == null ? message : '$message (${osError.message})',
  PlatformException(:final message) => message ?? 'That did not work',
  _ => err.toString(),
};
