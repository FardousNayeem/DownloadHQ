import 'models.dart';

class SyncResult {
  const SyncResult({required this.playlist, required this.added, required this.removed});

  final Playlist playlist;

  /// Ids that appeared since the previous sync.
  final List<String> added;

  /// Ids that disappeared from the remote playlist since the previous sync.
  final List<String> removed;
}

/// Merges a fresh remote listing into the local playlist.
///
/// Rules:
/// - First sync (never synced before): everything is imported, nothing is
///   flagged new. The user picks what to download from the full list.
/// - Later syncs: unseen ids are flagged [Entry.isNew].
/// - Ids gone from remote are kept and flagged [Entry.removedFromSource];
///   a downloaded file is never forgotten because YouTube dropped the video.
/// - Local state (file, ignored, isNew) always survives a sync.
SyncResult mergeRemote(Playlist local, RemotePlaylist remote, DateTime now) {
  final firstSync = local.lastSynced == null;
  final byId = {for (final e in local.entries) e.id: e};
  final remoteIds = <String>{};
  final added = <String>[];
  final merged = <Entry>[];

  for (var i = 0; i < remote.entries.length; i++) {
    final r = remote.entries[i];
    if (!remoteIds.add(r.id)) continue; // playlists can contain duplicates
    final old = byId[r.id];
    if (old == null) {
      if (!firstSync) added.add(r.id);
      merged.add(
        Entry(
          id: r.id,
          title: r.title,
          channel: r.channel,
          duration: r.duration,
          thumbnailUrl: r.thumbnailUrl,
          position: i,
          firstSeen: now,
          isNew: !firstSync && !r.unavailable,
          unavailable: r.unavailable,
        ),
      );
    } else {
      merged.add(
        old.copyWith(
          // Unavailable placeholders carry "[Private video]" as title; keep the
          // real title we saw earlier.
          title: r.unavailable ? null : r.title,
          channel: r.channel,
          duration: r.duration,
          thumbnailUrl: r.thumbnailUrl,
          position: i,
          unavailable: r.unavailable,
          removedFromSource: false,
        ),
      );
    }
  }

  final removed = <String>[];
  var tail = merged.length;
  for (final e in local.entries) {
    if (remoteIds.contains(e.id)) continue;
    if (!e.removedFromSource) removed.add(e.id);
    merged.add(e.copyWith(removedFromSource: true, position: tail++));
  }

  return SyncResult(
    playlist: local.copyWith(
      title: remote.title,
      channel: remote.channel,
      entries: merged,
      lastSynced: now,
      lastSyncError: null,
    ),
    added: added,
    removed: removed,
  );
}
