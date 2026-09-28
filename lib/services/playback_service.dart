import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../data/json_store.dart';
import '../domain/models.dart';

enum PlayRepeat { off, all, one }

/// One player for the whole app, so audio keeps going while you browse.
///
/// The queue lives here, not in mpv: mpv gets one file at a time. Handing it
/// the whole queue (`loadlist`) made any file it could not open vanish
/// silently, and playback jumped to whatever came next. Now a file that fails
/// stays current and [error] says why.
class PlaybackService extends ChangeNotifier {
  PlaybackService({JsonStore? state}) : _store = state {
    _restore();
    _subs = [
      player.stream.volume.listen((_) => notifyListeners()),
      // Remember the spot every few seconds, so a crash or a closed app
      // loses little.
      player.stream.position.listen((pos) {
        if (pos.inSeconds % 5 == 0 && pos.inSeconds != _lastSavedSecond) {
          _lastSavedSecond = pos.inSeconds;
          _remember();
        }
      }),
      player.stream.playing.listen((on) {
        if (!on) _remember();
      }),
      player.stream.playing.listen((_) => notifyListeners()),
      player.stream.completed.listen((done) {
        if (done && !_opening) _onCompleted();
      }),
      player.stream.error.listen((e) {
        // mpv also logs recoverable errors (one bad frame, a broken subtitle
        // track) mid-play. Only a file that never started counts.
        if (_queue.isEmpty || player.state.duration > Duration.zero) return;
        _error = 'This file could not be played ($e). Try opening it in another player.';
        notifyListeners();
      }),
      player.stream.rate.listen((_) => notifyListeners()),
    ];
  }

  final mk.Player player = mk.Player();

  /// One video surface for the life of the player. Creating a controller per
  /// visit to the player screen would stack up native textures.
  late final VideoController video = VideoController(player);
  late final List<StreamSubscription> _subs;

  /// Play order: the list order, or a shuffle of it with the current track first.
  List<Entry> _queue = const [];

  /// The queue in its original order, restored when shuffle is turned off.
  List<Entry> _ordered = const [];
  int _index = 0;
  bool _shuffle = false;
  PlayRepeat _repeat = PlayRepeat.off;
  String? _error;

  final JsonStore? _store;

  /// Where each saved video was left, by entry id. Only for tracks long
  /// enough to be worth resuming (see [resumeMinLength]).
  final Map<String, int> _positions = {};
  int _lastSavedSecond = -1;
  double _volumeBeforeMute = 100;

  /// Set when the current track picked up where it was left; the player
  /// offers "start over" while it is.
  Duration? resumedFrom;

  /// Sleep timer: pause at [sleepAt], or when the current track ends.
  DateTime? sleepAt;
  bool sleepAfterTrack = false;
  Timer? _sleepTimer;

  /// Songs start over; videos and long mixes resume.
  static const resumeMinLength = Duration(minutes: 5);

  /// True while a file is being opened; mpv reports the previous one as
  /// completed on the way, which must not advance the queue.
  bool _opening = false;

  Entry? get current => _queue.isEmpty ? null : _queue[_index.clamp(0, _queue.length - 1)];
  int get index => _index;
  bool get playing => player.state.playing;
  bool get hasNext => _index < _queue.length - 1 || (_repeat == PlayRepeat.all && _queue.length > 1);
  bool get hasPrevious => _index > 0;
  double get rate => player.state.rate;
  double get volume => player.state.volume;
  bool get muted => player.state.volume == 0;
  bool get sleepSet => sleepAt != null || sleepAfterTrack;

  /// Why the current file does not play, in words for a person. Null while fine.
  String? get error => _error;

  /// Decided by the file, not the playlist setting, which may have changed.
  bool get isVideo => isVideoPath(current?.filePath);
  List<Entry> get queue => _queue;
  bool get shuffle => _shuffle;
  PlayRepeat get repeat => _repeat;

  /// Plays the downloaded entries of a list, starting at [start].
  Future<void> playAll(List<Entry> entries, {Entry? start}) async {
    final local = entries.where((e) => e.isDownloaded).toList();
    if (local.isEmpty) return;
    _ordered = local;
    final first = start ?? (_shuffle ? (local.toList()..shuffle()).first : local.first);
    _queue = _shuffle ? _shuffledFrom(first) : local;
    await _playAt(_queue.indexWhere((e) => e.id == first.id).clamp(0, _queue.length - 1));
  }

  /// Current track first, the rest in random order.
  List<Entry> _shuffledFrom(Entry first) => [first, ...(_ordered.where((e) => e.id != first.id).toList()..shuffle())];

  Future<void> _playAt(int i, {Duration? position, bool play = true, bool resume = true}) async {
    await _remember();
    _index = i;
    _error = null;
    resumedFrom = null;
    final e = current;
    notifyListeners();
    if (e == null) return;
    final path = e.filePath;
    if (path == null || !await File(path).exists()) {
      await player.stop();
      _error = 'The file is missing. It may have been moved, renamed or deleted outside DownloadHQ.';
      notifyListeners();
      return;
    }
    _opening = true;
    try {
      await _clearSubtitle();
      await player.open(mk.Media(path), play: play);
      final saved = _positions[e.id];
      if (position != null) {
        await player.seek(position);
      } else if (resume && saved != null) {
        await _seekWhenReady(Duration(seconds: saved));
        resumedFrom = Duration(seconds: saved);
      }
    } catch (err) {
      _error = 'This file could not be opened: $err';
    } finally {
      _opening = false;
    }
    notifyListeners();
  }

  /// media_kit only clears its subtitle line when a subtitle track is
  /// chosen. When the file changes, mpv reports "no text" in a form
  /// media_kit ignores, so the last line of the previous video stayed on
  /// screen over the next one. Choosing the automatic track (mpv's default
  /// anyway) resets it.
  Future<void> _clearSubtitle() async {
    try {
      await player.setSubtitleTrack(mk.SubtitleTrack.auto());
    } catch (_) {}
  }

  /// mpv takes a seek only once the file is loaded (duration known).
  Future<void> _seekWhenReady(Duration to) async {
    if (player.state.duration == Duration.zero) {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero);
    }
    await player.seek(to);
  }

  void _onCompleted() {
    if (_queue.isEmpty || _error != null) return;
    final done = current;
    if (done != null && _positions.remove(done.id) != null) _save();
    if (sleepAfterTrack) {
      cancelSleep();
      return;
    }
    // A file mpv failed to open also ends as "completed", with no duration.
    // Moving on would hide the failure; say so and stay.
    if (player.state.duration == Duration.zero) {
      _error = 'This file could not be played. Try opening it in another player.';
      notifyListeners();
      return;
    }
    if (_repeat == PlayRepeat.one) {
      _playAt(_index);
    } else if (_index < _queue.length - 1) {
      _playAt(_index + 1);
    } else if (_repeat == PlayRepeat.all) {
      _playAt(0);
    }
  }

  Future<void> toggle() async {
    if (_error != null && current != null) return _playAt(_index);
    // After the last track ends mpv sits at the end; play means start over.
    if (player.state.completed) return _playAt(_index);
    await player.playOrPause();
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    if (_index < _queue.length - 1) return _playAt(_index + 1);
    if (_repeat == PlayRepeat.all) return _playAt(0);
  }

  /// Restarts the track when more than a few seconds in, like every player.
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (player.state.position > const Duration(seconds: 4) || _index == 0) {
      await player.seek(Duration.zero);
      return;
    }
    await _playAt(_index - 1);
  }

  Future<void> jump(int i) async {
    if (i < 0 || i >= _queue.length) return;
    await _playAt(i);
  }

  Future<void> seekBy(Duration d) async {
    final dur = player.state.duration;
    var to = player.state.position + d;
    if (to < Duration.zero) to = Duration.zero;
    if (dur > Duration.zero && to > dur) to = dur;
    await player.seek(to);
  }

  Future<void> setRate(double r) async {
    await player.setRate(r);
    _save();
  }

  /// 0 to 100.
  Future<void> setVolume(double v) async {
    await player.setVolume(v.clamp(0, 100).toDouble());
    _save();
  }

  Future<void> changeVolume(double by) => setVolume(volume + by);

  Future<void> toggleMute() async {
    if (muted) {
      await setVolume(_volumeBeforeMute <= 0 ? 60 : _volumeBeforeMute);
    } else {
      _volumeBeforeMute = volume;
      await setVolume(0);
    }
  }

  /// Plays the current track from its beginning, dropping the saved spot.
  Future<void> startOver() async {
    final e = current;
    if (e != null) _positions.remove(e.id);
    resumedFrom = null;
    await player.seek(Duration.zero);
    _save();
    notifyListeners();
  }

  void dismissResumed() {
    resumedFrom = null;
    notifyListeners();
  }

  /// Pauses after [d]; null pauses when the current track ends.
  void setSleep(Duration? d) {
    _sleepTimer?.cancel();
    sleepAfterTrack = d == null;
    sleepAt = d == null ? null : DateTime.now().add(d);
    if (d != null) {
      _sleepTimer = Timer(d, () async {
        await player.pause();
        cancelSleep();
      });
    }
    notifyListeners();
  }

  void cancelSleep() {
    _sleepTimer?.cancel();
    sleepAt = null;
    sleepAfterTrack = false;
    notifyListeners();
  }

  /// Saves where the current track is. Near the start or the end there is
  /// nothing worth resuming, so the spot is dropped instead.
  Future<void> _remember() async {
    final e = current;
    if (e == null || _error != null || _opening) return;
    final dur = player.state.duration;
    final pos = player.state.position;
    if (dur < resumeMinLength) return;
    final worth = pos > const Duration(seconds: 15) && pos < dur - const Duration(seconds: 20);
    final changed = worth ? _positions[e.id] != pos.inSeconds : _positions.containsKey(e.id);
    if (!changed) return;
    worth ? _positions[e.id] = pos.inSeconds : _positions.remove(e.id);
    _save();
  }

  Future<void> _restore() async {
    final j = await _store?.read();
    if (j is! Map) return;
    final pos = j['positions'];
    if (pos is Map) {
      for (final MapEntry(:key, :value) in pos.entries) {
        if (key is String && value is int) _positions.putIfAbsent(key, () => value);
      }
    }
    final vol = (j['volume'] as num?)?.toDouble();
    if (vol != null) await player.setVolume(vol.clamp(0, 100).toDouble());
    final r = (j['rate'] as num?)?.toDouble();
    if (r != null && r >= 0.25 && r <= 4) await player.setRate(r);
  }

  void _save() => _store?.write({'volume': volume, 'rate': rate, 'positions': _positions});

  void cycleRepeat() {
    _repeat = PlayRepeat.values[(_repeat.index + 1) % PlayRepeat.values.length];
    notifyListeners();
  }

  /// Plays [e] right after the current track (adds it if not queued yet).
  void playNext(Entry e) {
    if (!e.isDownloaded) return;
    if (_queue.isEmpty) {
      playAll([e]);
      return;
    }
    final q = [..._queue]..removeWhere((x) => x.id == e.id);
    final at = q.indexWhere((x) => x.id == current?.id);
    q.insert(at + 1, e);
    _queue = q;
    if (!_ordered.any((x) => x.id == e.id)) _ordered = [..._ordered, e];
    _index = at;
    notifyListeners();
  }

  /// Shuffles in Dart; only the order of what comes next changes.
  Future<void> setShuffle(bool on) async {
    _shuffle = on;
    final at = current;
    if (at != null) {
      _queue = on ? _shuffledFrom(at) : _ordered;
      _index = _queue.indexWhere((e) => e.id == at.id).clamp(0, _queue.length - 1);
    }
    notifyListeners();
  }

  /// Picks up a changed entry (renamed file, new title) without interrupting.
  void refresh(Entry e) {
    List<Entry> swap(List<Entry> l) => [for (final x in l) x.id == e.id ? e : x];
    if (!_queue.any((x) => x.id == e.id)) return;
    _queue = swap(_queue);
    _ordered = swap(_ordered);
    notifyListeners();
  }

  /// Stops playback if [entryId] is part of the queue (its file is going away).
  Future<void> forget(String entryId) async {
    if (_queue.any((e) => e.id == entryId)) await stop();
    if (_positions.remove(entryId) != null) _save();
  }

  /// Stops and clears the queue; the mini player goes away.
  Future<void> stop() async {
    await _remember();
    cancelSleep();
    await player.stop();
    await _clearSubtitle();
    _queue = _ordered = const [];
    _index = 0;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _sleepTimer?.cancel();
    player.dispose();
    super.dispose();
  }
}

bool isVideoPath(String? path) =>
    path != null && const {'.mp4', '.mkv', '.webm', '.mov', '.m4v', '.avi'}.contains(p.extension(path).toLowerCase());
