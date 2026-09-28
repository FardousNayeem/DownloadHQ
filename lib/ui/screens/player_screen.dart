import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../services/file_actions.dart';
import '../../services/playback_service.dart';
import '../format.dart';
import '../widgets/common.dart';
import '../widgets/entry_actions.dart';

/// Keyboard: space/K play-pause, left/right seek 5s, J/L seek 10s, up/down
/// volume, M mute, N/P next and previous, F fullscreen.
Map<ShortcutActivator, VoidCallback> _shortcuts(PlaybackService pb, {VoidCallback? fullscreen}) => {
  const SingleActivator(LogicalKeyboardKey.space): pb.toggle,
  const SingleActivator(LogicalKeyboardKey.keyK): pb.toggle,
  const SingleActivator(LogicalKeyboardKey.arrowLeft): () => pb.seekBy(const Duration(seconds: -5)),
  const SingleActivator(LogicalKeyboardKey.arrowRight): () => pb.seekBy(const Duration(seconds: 5)),
  const SingleActivator(LogicalKeyboardKey.keyJ): () => pb.seekBy(const Duration(seconds: -10)),
  const SingleActivator(LogicalKeyboardKey.keyL): () => pb.seekBy(const Duration(seconds: 10)),
  const SingleActivator(LogicalKeyboardKey.arrowUp): () => pb.changeVolume(5),
  const SingleActivator(LogicalKeyboardKey.arrowDown): () => pb.changeVolume(-5),
  const SingleActivator(LogicalKeyboardKey.keyM): pb.toggleMute,
  const SingleActivator(LogicalKeyboardKey.keyN): pb.next,
  const SingleActivator(LogicalKeyboardKey.keyP): pb.previous,
  const SingleActivator(LogicalKeyboardKey.keyF): ?fullscreen,
};

/// Subtitles half again as large as media_kit's default (32), which read
/// small, most of all in the docked player. media_kit still scales them
/// with the video's size.
const subtitleStyle = SubtitleViewConfiguration(
  style: TextStyle(height: 1.4, fontSize: 48, color: Color(0xFFFFFFFF), backgroundColor: Color(0xAA000000)),
  padding: EdgeInsets.fromLTRB(16, 0, 16, 28),
);

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  static Future<void> openFullscreen(BuildContext context) => Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => const _FullscreenPlayer(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pb = AppScope.of(context).playback;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: pb,
      builder: (context, _) {
        final e = pb.current;
        void fullscreen() => pb.isVideo ? openFullscreen(context) : null;
        return CallbackShortcuts(
          bindings: _shortcuts(pb, fullscreen: fullscreen),
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(PhosphorIconsRegular.caretDown),
                  onPressed: () => Navigator.pop(context),
                ),
                title: Text('Now playing', style: t.textTheme.titleMedium),
                centerTitle: true,
                actions: [
                  if (e != null) _SleepButton(pb: pb),
                  if (e != null)
                    IconButton(
                      tooltip: 'More',
                      icon: const Icon(PhosphorIconsBold.dotsThree),
                      onPressed: () => _moreFor(context, pb),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              body: e == null
                  ? const EmptyState(
                      icon: PhosphorIconsRegular.playCircle,
                      title: 'Nothing playing',
                      body: 'Open a playlist and tap a saved video.',
                    )
                  : LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth >= 900 || (c.maxWidth > c.maxHeight && c.maxWidth >= 600);
                        final compact = c.maxHeight < 520;
                        final details = _Details(pb: pb, compact: compact, onFullscreen: fullscreen);
                        if (wide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    // The video takes what the controls leave, never more.
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(Tokens.gutter, 0, Tokens.gutter, 0),
                                        child: _Stage(pb: pb, onFullscreen: fullscreen),
                                      ),
                                    ),
                                    details,
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: c.maxWidth >= 1200 ? 400 : 320,
                                child: _QueuePanel(pb: pb),
                              ),
                            ],
                          );
                        }
                        final stageH = (c.maxWidth * 9 / 16).clamp(120.0, c.maxHeight * 0.42);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
                              child: SizedBox(
                                height: stageH,
                                child: _Stage(pb: pb, onFullscreen: fullscreen),
                              ),
                            ),
                            details,
                            Expanded(child: _QueuePanel(pb: pb)),
                          ],
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  static void _moreFor(BuildContext context, PlaybackService pb) {
    final e = pb.current;
    if (e == null) return;
    final s = AppScope.of(context);
    for (final pl in s.library.playlists) {
      if (pl.entry(e.id)?.filePath == e.filePath) {
        showEntryActions(context, playlistId: pl.id, entryId: e.id);
        return;
      }
    }
  }
}

/// Video, or artwork for audio. Tap plays or pauses; double-tap goes
/// fullscreen. A file that will not play shows why, in place.
class _Stage extends StatelessWidget {
  const _Stage({required this.pb, required this.onFullscreen});
  final PlaybackService pb;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final e = pb.current!;
    final error = pb.error;
    Widget content;
    if (error != null) {
      content = _ErrorCard(pb: pb, message: error);
    } else if (pb.isVideo) {
      content = GestureDetector(
        onTap: pb.toggle,
        onDoubleTap: onFullscreen,
        child: ColoredBox(
          color: const Color(0xFF0A0A0B),
          child: Video(controller: pb.video, controls: NoVideoControls, subtitleViewConfiguration: subtitleStyle),
        ),
      );
    } else {
      content = Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: LayoutBuilder(
            builder: (context, c) => EntryThumb(entry: e, width: c.maxWidth, radius: Tokens.radiusSurface),
          ),
        ),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(Tokens.radiusSurface), child: content);
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.pb, required this.message});
  final PlaybackService pb;
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final path = pb.current?.filePath;
    return ColoredBox(
      color: t.colorScheme.surfaceContainerHigh,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(PhosphorIconsRegular.warningCircle, color: t.colorScheme.error, size: 28),
                const SizedBox(height: 10),
                Text(message, style: t.textTheme.bodyMedium),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (path != null)
                      FilledButton.icon(
                        onPressed: () => FileActions.openExternally(
                          path,
                        ).catchError((Object err) => context.mounted ? showMessage(context, '$err') : null),
                        icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
                        label: const Text('Open elsewhere'),
                      ),
                    OutlinedButton(onPressed: pb.toggle, child: const Text('Try again')),
                    if (pb.hasNext) OutlinedButton(onPressed: pb.next, child: const Text('Skip')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Title, seek bar and transport, sized to fit under the stage.
class _Details extends StatelessWidget {
  const _Details({required this.pb, required this.compact, required this.onFullscreen});
  final PlaybackService pb;
  final bool compact;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = pb.current!;
    return Padding(
      padding: EdgeInsets.fromLTRB(Tokens.gutter, compact ? 8 : 16, Tokens.gutter, compact ? 4 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: e.title,
            waitDuration: const Duration(milliseconds: 600),
            child: Text(
              e.title,
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: (compact ? t.textTheme.titleMedium : t.textTheme.titleLarge)?.copyWith(
                fontSize: compact ? 16 : 19,
              ),
            ),
          ),
          if (e.channel != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                e.channel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
          if (pb.resumedFrom != null) _ResumedChip(pb: pb),
          SizedBox(height: compact ? 2 : 8),
          _SeekBar(pb: pb, onFullscreen: pb.isVideo ? onFullscreen : null),
          _Transport(pb: pb),
        ],
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.pb, this.onFullscreen, this.onDark = false});
  final PlaybackService pb;
  final VoidCallback? onFullscreen;
  final bool onDark;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// While dragging, the thumb follows the finger; mpv seeks once on release.
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final pb = widget.pb;
    final player = pb.player;
    final t = Theme.of(context);
    final muted = widget.onDark ? Colors.white70 : t.colorScheme.onSurfaceVariant;
    final small = t.textTheme.bodySmall?.copyWith(color: muted, fontFeatures: const [FontFeature.tabularFigures()]);
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (context, _) {
        final pos = player.state.position;
        final dur = player.state.duration;
        final max = dur.inMilliseconds.toDouble();
        final value = _drag ?? pos.inMilliseconds.clamp(0, max <= 0 ? 0 : max).toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                inactiveTrackColor: widget.onDark ? Colors.white24 : t.colorScheme.outline,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              ),
              child: Slider(
                value: value.clamp(0, max <= 0 ? 1 : max),
                max: max <= 0 ? 1 : max,
                onChanged: max <= 0 ? null : (v) => setState(() => _drag = v),
                onChangeEnd: max <= 0
                    ? null
                    : (v) async {
                        await player.seek(Duration(milliseconds: v.round()));
                        if (mounted) setState(() => _drag = null);
                      },
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 4),
                Text(formatDuration(Duration(milliseconds: value.round())), style: small),
                const Spacer(),
                _Tool(
                  tooltip: 'Back 10 seconds',
                  icon: PhosphorIconsRegular.clockCounterClockwise,
                  onDark: widget.onDark,
                  onPressed: () => pb.seekBy(const Duration(seconds: -10)),
                ),
                _Tool(
                  tooltip: 'Forward 10 seconds',
                  icon: PhosphorIconsRegular.clockClockwise,
                  onDark: widget.onDark,
                  onPressed: () => pb.seekBy(const Duration(seconds: 10)),
                ),
                _VolumeButton(pb: pb, onDark: widget.onDark),
                _SpeedButton(pb: pb, onDark: widget.onDark),
                if (widget.onFullscreen != null)
                  _Tool(
                    tooltip: widget.onDark ? 'Exit fullscreen (F)' : 'Fullscreen (F)',
                    icon: widget.onDark ? PhosphorIconsRegular.cornersIn : PhosphorIconsRegular.cornersOut,
                    onDark: widget.onDark,
                    onPressed: widget.onFullscreen!,
                  ),
                const Spacer(),
                Text(formatDuration(dur), style: small),
                const SizedBox(width: 4),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.tooltip, required this.icon, required this.onPressed, this.onDark = false, this.color});
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool onDark;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 20,
    visualDensity: VisualDensity.compact,
    color: color ?? (onDark ? Colors.white : null),
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

/// Speaker icon: tap for a volume slider, scroll over it to nudge the level.
class _VolumeButton extends StatelessWidget {
  const _VolumeButton({required this.pb, this.onDark = false});
  final PlaybackService pb;
  final bool onDark;

  static IconData iconFor(double v) => v == 0
      ? PhosphorIconsRegular.speakerSlash
      : v < 34
      ? PhosphorIconsRegular.speakerNone
      : v < 67
      ? PhosphorIconsRegular.speakerLow
      : PhosphorIconsRegular.speakerHigh;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) pb.changeVolume(e.scrollDelta.dy < 0 ? 5 : -5);
      },
      child: MenuAnchor(
        alignmentOffset: const Offset(-90, 0),
        menuChildren: [
          ListenableBuilder(
            listenable: pb,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: 240,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: pb.muted ? 'Unmute (M)' : 'Mute (M)',
                      onPressed: pb.toggleMute,
                      icon: Icon(iconFor(pb.volume), size: 20),
                    ),
                    Expanded(
                      child: Slider(
                        value: pb.volume.clamp(0, 100),
                        max: 100,
                        onChanged: pb.setVolume,
                        semanticFormatterCallback: (v) => '${v.round()} percent',
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${pb.volume.round()}',
                        textAlign: TextAlign.end,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ],
        builder: (context, menu, _) => _Tool(
          tooltip: 'Volume ${pb.volume.round()}% (Up/Down)',
          icon: iconFor(pb.volume),
          onDark: onDark,
          color: pb.muted ? Theme.of(context).colorScheme.error : null,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
    );
  }
}

/// Moon in the app bar: pause after a while, or when this track ends.
class _SleepButton extends StatelessWidget {
  const _SleepButton({required this.pb});
  final PlaybackService pb;

  static const _minutes = [15, 30, 45, 60, 90];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final at = pb.sleepAt;
    final tip = pb.sleepAfterTrack
        ? 'Sleep timer: pauses when this track ends'
        : at != null
        ? 'Sleep timer: pauses at ${TimeOfDay.fromDateTime(at).format(context)}'
        : 'Sleep timer';
    return PopupMenuButton<int>(
      tooltip: tip,
      icon: Icon(
        pb.sleepSet ? PhosphorIconsFill.moon : PhosphorIconsRegular.moon,
        color: pb.sleepSet ? cs.primary : null,
      ),
      onSelected: (v) => switch (v) {
        0 => pb.cancelSleep(),
        -1 => pb.setSleep(null),
        _ => pb.setSleep(Duration(minutes: v)),
      },
      itemBuilder: (_) => [
        for (final m in _minutes) PopupMenuItem(value: m, child: Text('In $m minutes')),
        const PopupMenuItem(value: -1, child: Text('When this track ends')),
        if (pb.sleepSet) const PopupMenuItem(value: 0, child: Text('Turn off')),
      ],
    );
  }
}

/// "Resumed at 12:34" with a way back to the beginning.
class _ResumedChip extends StatelessWidget {
  const _ResumedChip({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(PhosphorIconsRegular.clockCounterClockwise, size: 14, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          Text('Resumed at ${formatDuration(pb.resumedFrom)}', style: t.textTheme.bodySmall),
          const SizedBox(width: 4),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onPressed: pb.startOver,
            child: const Text('Start over'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            onPressed: pb.dismissResumed,
            icon: const Icon(PhosphorIconsBold.x),
          ),
        ],
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.pb, this.onDark = false});
  final PlaybackService pb;
  final bool onDark;

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  static String _label(double r) =>
      '${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 2).replaceFirst(RegExp(r'0$'), '')}x';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = pb.rate;
    final changed = (r - 1).abs() > 0.01;
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      initialValue: r,
      onSelected: pb.setRate,
      itemBuilder: (_) => [for (final v in _rates) PopupMenuItem(value: v, child: Text(v == 1 ? 'Normal' : _label(v)))],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          _label(r),
          style: t.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: changed ? t.colorScheme.primary : (onDark ? Colors.white : t.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.pb, this.onDark = false});
  final PlaybackService pb;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final idle = onDark ? Colors.white : cs.onSurface;
    final repeatIcon = pb.repeat == PlayRepeat.one ? PhosphorIconsRegular.repeatOnce : PhosphorIconsRegular.repeat;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Tool(
          tooltip: pb.shuffle ? 'Shuffle on' : 'Shuffle off',
          icon: PhosphorIconsRegular.shuffle,
          color: pb.shuffle ? cs.primary : idle.withValues(alpha: 0.7),
          onPressed: () => pb.setShuffle(!pb.shuffle),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Previous (P)',
          iconSize: 24,
          color: idle,
          onPressed: pb.previous,
          icon: const Icon(PhosphorIconsFill.skipBack),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: pb.playing ? 'Pause (Space)' : 'Play (Space)',
          iconSize: 24,
          style: IconButton.styleFrom(minimumSize: const Size(52, 52), fixedSize: const Size(52, 52)),
          onPressed: pb.toggle,
          icon: Icon(pb.playing ? PhosphorIconsFill.pause : PhosphorIconsFill.play),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Next (N)',
          iconSize: 24,
          color: idle,
          onPressed: pb.hasNext ? pb.next : null,
          icon: const Icon(PhosphorIconsFill.skipForward),
        ),
        const SizedBox(width: 12),
        _Tool(
          tooltip: switch (pb.repeat) {
            PlayRepeat.off => 'Repeat off',
            PlayRepeat.all => 'Repeat all',
            PlayRepeat.one => 'Repeat this one',
          },
          icon: repeatIcon,
          color: pb.repeat == PlayRepeat.off ? idle.withValues(alpha: 0.7) : cs.primary,
          onPressed: pb.cycleRepeat,
        ),
      ],
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({required this.pb});
  final PlaybackService pb;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final left = pb.queue.length - pb.index - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 4),
          child: Row(
            children: [
              Text('Up next', style: t.textTheme.titleMedium),
              const SizedBox(width: 8),
              if (left > 0) Text('$left more', style: t.textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(child: _Queue(pb: pb)),
      ],
    );
  }
}

class _Queue extends StatefulWidget {
  const _Queue({required this.pb});
  final PlaybackService pb;

  @override
  State<_Queue> createState() => _QueueState();
}

class _QueueState extends State<_Queue> {
  static const _rowHeight = 64.0;
  final _scroll = ScrollController();
  String? _shownId;

  /// Keeps the current track in view as the queue advances.
  void _follow() {
    final id = widget.pb.current?.id;
    if (id == null || id == _shownId || !_scroll.hasClients) return;
    _shownId = id;
    final target = (widget.pb.index * _rowHeight - _rowHeight).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pb = widget.pb;
    final t = Theme.of(context);
    final current = pb.current;
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 24),
      itemExtent: _rowHeight,
      itemCount: pb.queue.length,
      itemBuilder: (context, i) {
        final e = pb.queue[i];
        final active = e.id == current?.id;
        return Material(
          color: active ? t.colorScheme.primary.withValues(alpha: 0.10) : Colors.transparent,
          child: InkWell(
            onTap: () => pb.jump(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 8),
              child: Row(
                children: [
                  EntryThumb(entry: e, width: 64, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodyMedium?.copyWith(
                            color: active ? t.colorScheme.primary : null,
                            fontWeight: active ? FontWeight.w600 : null,
                          ),
                        ),
                        Text(formatDuration(e.duration), style: t.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (active)
                    Icon(
                      pb.playing ? PhosphorIconsFill.speakerHigh : PhosphorIconsFill.pause,
                      size: 16,
                      color: t.colorScheme.primary,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Video filling the screen, controls over it that fade after a few seconds
/// without input. Esc, the button, or back leaves.
class _FullscreenPlayer extends StatefulWidget {
  const _FullscreenPlayer();

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  bool _chrome = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    defaultEnterNativeFullscreen();
    _poke();
  }

  @override
  void dispose() {
    _hide?.cancel();
    defaultExitNativeFullscreen();
    super.dispose();
  }

  void _poke() {
    _hide?.cancel();
    if (!_chrome) setState(() => _chrome = true);
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && AppScope.of(context).playback.playing) setState(() => _chrome = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pb = AppScope.of(context).playback;
    void exit() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: {
        ..._shortcuts(pb, fullscreen: exit),
        const SingleActivator(LogicalKeyboardKey.escape): exit,
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, _) {
          _poke();
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF050506),
          body: MouseRegion(
            cursor: _chrome ? SystemMouseCursors.basic : SystemMouseCursors.none,
            onHover: (_) => _poke(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _chrome ? setState(() => _chrome = false) : _poke(),
              onDoubleTap: exit,
              child: ListenableBuilder(
                listenable: pb,
                builder: (context, _) {
                  final e = pb.current;
                  if (e == null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => exit());
                    return const SizedBox.shrink();
                  }
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Video(
                        controller: pb.video,
                        controls: NoVideoControls,
                        fill: const Color(0xFF050506),
                        subtitleViewConfiguration: subtitleStyle,
                      ),
                      IgnorePointer(
                        ignoring: !_chrome,
                        child: AnimatedOpacity(
                          opacity: _chrome ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: _FullscreenChrome(pb: pb, onExit: exit, onInteract: _poke),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenChrome extends StatelessWidget {
  const _FullscreenChrome({required this.pb, required this.onExit, required this.onInteract});
  final PlaybackService pb;
  final VoidCallback onExit;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const scrim = Color(0xCC000000);
    return Listener(
      onPointerDown: (_) => onInteract(),
      child: Column(
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scrim, Color(0x00000000)],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Exit fullscreen (Esc)',
                      color: Colors.white,
                      onPressed: onExit,
                      icon: const Icon(PhosphorIconsRegular.arrowLeft),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pb.current?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          if (pb.error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                pb.error!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          const Spacer(),
          DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [scrim, Color(0x00000000)],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SeekBar(pb: pb, onDark: true, onFullscreen: onExit),
                        _Transport(pb: pb, onDark: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
