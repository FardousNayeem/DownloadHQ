import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../screens/player_screen.dart';
import 'common.dart';

/// Docked above the navigation; hidden when nothing is loaded.
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
                      child: Padding(
                        padding: const EdgeInsets.all(8),
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
                                  if (e.channel != null)
                                    Text(
                                      e.channel!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.textTheme.bodySmall,
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
                              onPressed: pb.next,
                              icon: const Icon(PhosphorIconsFill.skipForward),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
