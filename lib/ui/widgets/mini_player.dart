import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../services/playback_service.dart';
import '../screens/player_screen.dart';
import 'common.dart';

/// Docked above the navigation; hidden when nothing is loaded. The cross
/// stops playback and dismisses it.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final pb = AppScope.of(context).playback;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: pb,
      builder: (context, _) {
        final e = pb.current;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: e == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Material(
                    color: t.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(Tokens.radiusSurface),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const PlayerScreen())),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                            child: Row(
                              children: [
                                EntryThumb(entry: e, width: 64, radius: 8),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: t.textTheme.bodyMedium,
                                      ),
                                      Text(
                                        pb.error != null ? 'Could not play this file' : (e.channel ?? ''),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: t.textTheme.bodySmall?.copyWith(
                                          color: pb.error != null ? t.colorScheme.error : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: pb.playing ? 'Pause' : 'Play',
                                  onPressed: pb.toggle,
                                  icon: Icon(pb.playing ? PhosphorIconsFill.pause : PhosphorIconsFill.play),
                                ),
                                IconButton(
                                  tooltip: 'Next',
                                  onPressed: pb.hasNext ? pb.next : null,
                                  icon: const Icon(PhosphorIconsFill.skipForward),
                                ),
                                IconButton(
                                  tooltip: 'Close player',
                                  onPressed: pb.stop,
                                  icon: Icon(PhosphorIconsBold.x, size: 18, color: t.colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          _ProgressLine(pb: pb),
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

/// Hairline of how far into the track playback is.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: pb.player.stream.position,
      builder: (context, _) {
        final dur = pb.player.state.duration.inMilliseconds;
        final pos = pb.player.state.position.inMilliseconds;
        return LinearProgressIndicator(
          value: dur <= 0 ? 0 : (pos / dur).clamp(0, 1),
          minHeight: 2,
          backgroundColor: Colors.transparent,
        );
      },
    );
  }
}
