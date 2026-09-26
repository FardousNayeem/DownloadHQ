import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../domain/models.dart';
import '../format.dart';
import 'common.dart';

Future<void> showGrabSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const GrabSheet(),
);

/// Picks what to save from the current page and how.
class GrabSheet extends StatefulWidget {
  const GrabSheet({super.key});

  @override
  State<GrabSheet> createState() => _GrabSheetState();
}

class _GrabSheetState extends State<GrabSheet> {
  static const _standardHeights = [360, 480, 720, 1080, 1440, 2160];

  late final List<RemoteEntry> _items;
  late final Set<String> _selected;
  late MediaMode _mode;
  late int _height;
  bool _tracking = false;

  /// Heights worth offering: standard steps up to what the item actually has.
  /// Playlist entries are listed flat, so their formats are unknown.
  List<int> get _heights {
    if (_items.length != 1) return const [360, 480, 720, 1080];
    final max = _items.first.heights.isEmpty ? 0 : _items.first.heights.last;
    final steps = _standardHeights.where((h) => h <= max).toList();
    return steps.isEmpty ? [max] : steps;
  }

  bool get _audioOnly => _items.length == 1 && _items.first.heights.isEmpty;

  @override
  void initState() {
    super.initState();
    final grab = AppScope.of(context).grab;
    _items = grab.result?.entries ?? const [];
    // One thing on the page: preselect it. A long list: let the user choose.
    _selected = {if (_items.length == 1) _items.first.id};
    _mode = _audioOnly ? MediaMode.audio : AppScope.of(context).settings.value.lastGrabMode;
    final hs = _heights;
    _height = hs.contains(720) ? 720 : hs.last;
  }

  void _download() {
    final s = AppScope.of(context);
    final picked = _items.where((e) => _selected.contains(e.id)).toList();
    final n = s.grab.download(picked, DownloadPrefs(mode: _mode, maxHeight: _height));
    // Remember a real choice only; audio-only pages force it.
    if (!_audioOnly) s.settings.update((x) => x.copyWith(lastGrabMode: _mode));
    Navigator.pop(context);
    showMessage(context, switch (n) {
      0 => 'Already saved or downloading.',
      1 => 'Downloading. It will appear under From the web.',
      _ => 'Queued $n downloads.',
    });
  }

  Future<void> _track() async {
    final s = AppScope.of(context);
    setState(() => _tracking = true);
    try {
      final p = await s.grab.track();
      if (!mounted) return;
      Navigator.pop(context);
      showMessage(context, 'Tracking "${p.title}". Find it in Library.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _tracking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final result = s.grab.result;
    final many = _items.length > 1;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: many ? 0.85 : 0.55,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  sliver: SliverList.list(
                    children: [
                      Text(
                        result?.title ?? 'This page',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        many ? '${_items.length} items on this page' : 'One item on this page',
                        style: t.textTheme.bodySmall,
                      ),
                      if (s.grab.trackablePlaylistId != null) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _tracking ? null : _track,
                          icon: _tracking
                              ? const ProgressRing(size: 16)
                              : const Icon(PhosphorIconsRegular.bellRinging, size: 18),
                          label: const Text('Track playlist for new videos'),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Text('Save as', style: t.textTheme.labelLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<MediaMode>(
                        segments: [
                          const ButtonSegment(
                            value: MediaMode.audio,
                            label: Text('Audio'),
                            icon: Icon(PhosphorIconsRegular.headphones),
                          ),
                          ButtonSegment(
                            value: MediaMode.video,
                            label: const Text('Video'),
                            icon: const Icon(PhosphorIconsRegular.filmStrip),
                            enabled: !_audioOnly,
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (v) => setState(() => _mode = v.first),
                      ),
                      if (_audioOnly) ...[
                        const SizedBox(height: 6),
                        Text('This page only offers audio.', style: t.textTheme.bodySmall),
                      ],
                      if (_mode == MediaMode.video) ...[
                        const SizedBox(height: 16),
                        Text(many ? 'Highest quality' : 'Quality', style: t.textTheme.labelLarge),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final h in _heights)
                              ChoiceChip(
                                label: Text('${h}p'),
                                selected: _height == h,
                                showCheckmark: false,
                                onSelected: (_) => setState(() => _height = h),
                              ),
                          ],
                        ),
                      ],
                      if (many) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Text('Items', style: t.textTheme.labelLarge),
                            const Spacer(),
                            TextButton(
                              onPressed: () => setState(
                                () => _selected.length == _items.length
                                    ? _selected.clear()
                                    : _selected.addAll(_items.map((e) => e.id)),
                              ),
                              child: Text(_selected.length == _items.length ? 'Clear' : 'Select all'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                SliverList.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final e = _items[i];
                    final meta = [
                      if (e.channel != null) e.channel!,
                      if (e.duration != null) formatDuration(e.duration),
                    ];
                    final asEntry = Entry(
                      id: e.id,
                      title: e.title,
                      thumbnailUrl: e.thumbnailUrl,
                      position: i,
                      firstSeen: DateTime(2000),
                    );
                    return InkWell(
                      onTap: many
                          ? () =>
                                setState(() => _selected.contains(e.id) ? _selected.remove(e.id) : _selected.add(e.id))
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        child: Row(
                          children: [
                            EntryThumb(entry: asEntry, width: many ? 88 : 128),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.textTheme.bodyLarge,
                                  ),
                                  if (meta.isNotEmpty) Text(meta.join('   '), style: t.textTheme.bodySmall),
                                ],
                              ),
                            ),
                            if (many)
                              Checkbox(
                                value: _selected.contains(e.id),
                                onChanged: (_) => setState(
                                  () => _selected.contains(e.id) ? _selected.remove(e.id) : _selected.add(e.id),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : _download,
                  icon: const Icon(PhosphorIconsBold.downloadSimple, size: 18),
                  label: Text(_selected.length <= 1 ? 'Download' : 'Download ${_selected.length}'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
