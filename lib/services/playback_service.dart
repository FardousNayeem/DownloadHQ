import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../domain/models.dart';

/// One player for the whole app, so audio keeps going while you browse.
class PlaybackService extends ChangeNotifier {
  PlaybackService() {
    _subs = [
      player.stream.playlist.listen((pl) {
        _index = pl.index;
        notifyListeners();
      }),
      player.stream.playing.listen((_) => notifyListeners()),
      player.stream.completed.listen((_) => notifyListeners()),
    ];
  }

  final mk.Player player = mk.Player();

  /// One video surface for the life of the player. Creating a controller per
  /// visit to the player screen would stack up native textures.
  late final VideoController video = VideoController(player);
  late final List<StreamSubscription> _subs;

  /// Always in the same order as the player's playlist, so an index means
  /// the same track on both sides.
  List<Entry> _queue = const [];

  /// The queue in its original order, restored when shuffle is turned off.
  List<Entry> _ordered = const [];
  int _index = 0;
  bool _shuffle = false;

  Entry? get current => _queue.isEmpty ? null : _queue[_index.clamp(0, _queue.length - 1)];
  bool get playing => player.state.playing;

  /// Decided by the file, not the playlist setting, which may have changed.
  bool get isVideo => RegExp(r'\.(mp4|mkv|webm|mov)$', caseSensitive: false).hasMatch(current?.filePath ?? '');
  List<Entry> get queue => _queue;
  bool get shuffle => _shuffle;

  /// Plays the downloaded entries of a list, starting at [start].
  Future<void> playAll(List<Entry> entries, {Entry? start}) async {
    final local = entries.where((e) => e.isDownloaded).toList();
    if (local.isEmpty) return;
    _ordered = local;
    final first = start ?? (_shuffle ? (local.toList()..shuffle()).first : local.first);
    await _load(_shuffle ? _shuffledFrom(first) : local, first);
  }

  /// Current track first, the rest in random order.
  List<Entry> _shuffledFrom(Entry first) => [first, ...(_ordered.where((e) => e.id != first.id).toList()..shuffle())];

  Future<void> _load(List<Entry> order, Entry at, {Duration? position}) async {
    _queue = order;
    _index = order.indexWhere((e) => e.id == at.id).clamp(0, order.length - 1);
    await player.open(mk.Playlist([for (final e in order) mk.Media(e.filePath!)], index: _index));
    if (position != null) await player.seek(position);
    notifyListeners();
  }

  Future<void> toggle() => player.playOrPause();
  Future<void> next() => player.next();
  Future<void> previous() => player.previous();

  /// Shuffles in Dart rather than in mpv: mpv reorders its playlist
  /// internally, which would make our queue and its indices disagree.
  Future<void> setShuffle(bool on) async {
    _shuffle = on;
    final at = current;
    if (at == null) return notifyListeners();
    final pos = player.state.position;
    final wasPlaying = playing;
    await _load(on ? _shuffledFrom(at) : _ordered, at, position: pos);
    if (!wasPlaying) await player.pause();
  }

  /// Stops playback if [entryId] is part of the queue (its file is going away).
  Future<void> forget(String entryId) async {
    if (_queue.any((e) => e.id == entryId)) await stop();
  }

  Future<void> stop() async {
    await player.stop();
    _queue = _ordered = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
