import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../services/playback_service.dart';
import '../format.dart';
import '../widgets/common.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  @override
  Widget build(BuildContext context) {
    final pb = AppScope.of(context).playback;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: pb,
      builder: (context, _) {
        final e = pb.current;
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Close',
              icon: const Icon(PhosphorIconsRegular.caretDown),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: e == null
              ? const EmptyState(
                  icon: PhosphorIconsRegular.playCircle,
                  title: 'Nothing playing',
                  body: 'Open a playlist and tap a saved video.',
                )
              : LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 900;
                    final stage = Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: pb.isVideo
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(Tokens.radiusSurface),
                                child: Video(controller: pb.video, controls: NoVideoControls),
                              )
                            : LayoutBuilder(
                                builder: (context, c) =>
                                    EntryThumb(entry: e, width: c.maxWidth, radius: Tokens.radiusSurface),
                              ),
                      ),
                    );
                    final controls = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 24, Tokens.gutter, 0),
                          child: Text(
                            e.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.titleLarge,
                          ),
                        ),
                        if (e.channel != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 0),
                            child: Text(
                              e.channel!,
                              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        _SeekBar(pb: pb),
                        _Controls(pb: pb),
                      ],
                    );
                    final queue = _Queue(pb: pb);
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: ListView(children: [stage, controls])),
                          Expanded(flex: 2, child: queue),
                        ],
                      );
                    }
                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(child: stage),
                        SliverToBoxAdapter(child: controls),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 24, Tokens.gutter, 8),
                            child: Text('Up next', style: t.textTheme.titleMedium),
                          ),
                        ),
                        SliverFillRemaining(child: queue),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    final player = pb.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (context, _) {
        final pos = player.state.position;
        final dur = player.state.duration;
        final max = dur.inMilliseconds.toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          child: Column(
            children: [
              Slider(
                value: pos.inMilliseconds.clamp(0, max <= 0 ? 0 : max).toDouble(),
                max: max <= 0 ? 1 : max,
                onChanged: max <= 0 ? null : (v) => player.seek(Duration(milliseconds: v.round())),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(formatDuration(pos), style: Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    Text(formatDuration(dur), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Shuffle',
            onPressed: () => pb.setShuffle(!pb.shuffle),
            icon: Icon(PhosphorIconsRegular.shuffle, color: pb.shuffle ? cs.primary : null),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Previous',
            iconSize: 30,
            onPressed: pb.previous,
            icon: const Icon(PhosphorIconsFill.skipBack),
          ),
          const SizedBox(width: 12),
          IconButton.filled(
            tooltip: pb.playing ? 'Pause' : 'Play',
            iconSize: 34,
            padding: const EdgeInsets.all(16),
            onPressed: pb.toggle,
            icon: Icon(pb.playing ? PhosphorIconsFill.pause : PhosphorIconsFill.play),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Next',
            iconSize: 30,
            onPressed: pb.next,
            icon: const Icon(PhosphorIconsFill.skipForward),
          ),
          const SizedBox(width: 56),
        ],
      ),
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final current = pb.current;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: pb.queue.length,
      itemBuilder: (context, i) {
        final e = pb.queue[i];
        final active = e.id == current?.id;
        return ListTile(
          leading: EntryThumb(entry: e, width: 64, radius: 8),
          title: Text(
            e.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: active ? t.colorScheme.primary : null),
          ),
          subtitle: Text(formatDuration(e.duration)),
          onTap: () => pb.player.jump(i),
        );
      },
    );
  }
}
