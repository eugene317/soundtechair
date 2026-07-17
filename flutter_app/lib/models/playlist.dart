import 'dart:math';

/// Where a playlist track's audio actually comes from. Only `youtube` is
/// usable today (Spotify isn't integrated yet) - this tag is what lets a
/// future Spotify source slot into the SAME playlist model without any
/// structural change: one more enum case, one more branch in the URL-dispatch
/// switch in SpeakerController, nothing else.
enum TrackSource { youtube, spotify }

String _generateId() {
  final rand = Random();
  return '${DateTime.now().microsecondsSinceEpoch}-${rand.nextInt(1 << 32)}';
}

class PlaylistTrack {
  /// Stable identity for THIS entry, distinct from [sourceId] - the same
  /// song can legitimately appear twice in a playlist (or in two playlists),
  /// so reorder/remove operations need a handle that isn't the content id.
  final String id;
  final TrackSource source;

  /// The id needed to actually replay this entry. For YouTube, the video id
  /// (StreamUrlBuilder.youtube turns this into a playable URL at play-time,
  /// never baked into a stored URL - so playlists stay valid even if the
  /// Stream Proxy URL setting changes later).
  final String sourceId;

  /// Display only - snapshotted at add-time, never used for playback.
  final String title;
  final String? imageUrl;

  /// Null for YouTube today (its reported duration is unreliable). Reserved
  /// for a future source (e.g. Spotify) that reports real duration.
  final int? durationMs;
  final int addedAt;

  const PlaylistTrack({
    required this.id,
    required this.source,
    required this.sourceId,
    required this.title,
    this.imageUrl,
    this.durationMs,
    required this.addedAt,
  });

  factory PlaylistTrack.youtube({
    required String videoId,
    required String title,
    String? imageUrl,
    int? durationSeconds,
  }) {
    return PlaylistTrack(
      id: _generateId(),
      source: TrackSource.youtube,
      sourceId: videoId,
      title: title,
      imageUrl: imageUrl,
      durationMs: durationSeconds == null ? null : durationSeconds * 1000,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.name,
        'sourceId': sourceId,
        'title': title,
        'imageUrl': imageUrl,
        'durationMs': durationMs,
        'addedAt': addedAt,
      };

  /// Returns null (rather than throwing) for an unrecognized source - lets
  /// the caller drop just this one track instead of failing the whole load.
  static PlaylistTrack? fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String?;
    final source = TrackSource.values.where((s) => s.name == sourceName).firstOrNull;
    if (source == null) return null;
    final id = json['id'] as String?;
    final sourceId = json['sourceId'] as String?;
    final title = json['title'] as String?;
    if (id == null || sourceId == null || title == null) return null;
    return PlaylistTrack(
      id: id,
      source: source,
      sourceId: sourceId,
      title: title,
      imageUrl: json['imageUrl'] as String?,
      durationMs: json['durationMs'] as int?,
      addedAt: json['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class Playlist {
  final String id;
  final String name;
  final int createdAt;
  final int updatedAt;

  /// List order IS play order (sequential-mode order) - no separate
  /// position field to keep in sync on every reorder.
  final List<PlaylistTrack> tracks;

  const Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.tracks,
  });

  factory Playlist.create(String name) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Playlist(id: _generateId(), name: name, createdAt: now, updatedAt: now, tracks: const []);
  }

  Playlist copyWith({String? name, List<PlaylistTrack>? tracks}) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      tracks: tracks ?? this.tracks,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      };

  static Playlist? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final name = json['name'] as String?;
    if (id == null || name == null) return null;
    final rawTracks = (json['tracks'] as List?) ?? const [];
    final tracks = rawTracks
        .map((t) => PlaylistTrack.fromJson(Map<String, dynamic>.from(t as Map)))
        .whereType<PlaylistTrack>()
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    return Playlist(
      id: id,
      name: name,
      createdAt: json['createdAt'] as int? ?? now,
      updatedAt: json['updatedAt'] as int? ?? now,
      tracks: tracks,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
