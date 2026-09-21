import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/search_result.dart';

/// Thrown by [TuneInApiClient.resolveStreamUrl] specifically when a station
/// resolved successfully but the stream itself is https:// - a confirmed,
/// permanent incompatibility with this speaker hardware, not a transient
/// network hiccup. Callers use this to distinguish "never going to work, stop
/// showing/retrying this one" from a plain null return (couldn't resolve
/// this time, worth trying again later).
class UnplayableStationException implements Exception {
  const UnplayableStationException();
}

/// Calls TuneIn's own public radio-directory API directly
/// (opml.radiotime.com) - unauthenticated, no backend of ours involved. This
/// same bare endpoint (as opposed to TuneIn's certified Partner API at
/// developer.tunein.com, which licensed apps use) has long, well-documented
/// precedent among open-source/hobbyist smart-speaker integrations - e.g.
/// Kodi's TuneIn addon, Logitech Media Server/Lyrion's
/// radiotime_handler.py, VLC's radiotime.lua, node-sonos-http-api, and an
/// "unofficial TuneIn API" documentation project.
class TuneInApiClient {
  static const _timeout = Duration(seconds: 15);

  static Future<List<RadioResult>> search(String query) async {
    final uri = Uri.parse(
      'https://opml.radiotime.com/Search.ashx?query=${Uri.encodeQueryComponent(query)}&render=json',
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('TuneIn search failed (HTTP ${response.statusCode})');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final body = (decoded['body'] as List?) ?? const [];
    return body
        .cast<Map<String, dynamic>>()
        // Only real, live stations - TuneIn's search results also mix in
        // shows/podcast episodes ("topics"), which this app has no player
        // for.
        .where((item) => item['type'] == 'audio' && item['item'] == 'station')
        .map((item) => RadioResult(
              name: item['text'] as String? ?? '',
              id: item['guide_id'] as String? ?? '',
              image: item['image'] as String?,
            ))
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  /// Resolves [stationId] to a real, directly-playable stream URL - ported
  /// 1:1 from this project's old relay-server.ps1 (Resolve-TuneInUrl/
  /// Resolve-PlaylistUrl). Most stations resolve straight to a final stream
  /// URL; some are one more hop away behind a .pls/.m3u playlist file (see
  /// [_resolvePlaylistUrl]).
  ///
  /// Returns null if TuneIn has nothing for this id or the resolve chain
  /// fails (network hiccup, bad response, etc) - a transient condition worth
  /// retrying later. Throws [UnplayableStationException] specifically when
  /// the chain resolves successfully but the stream itself is https:// - the
  /// speaker's own SetAVTransportURI rejects https:// sources outright
  /// (confirmed against real hardware), and unlike when a PC-side proxy sat
  /// in between, there's nothing left here to front an https-only origin
  /// with a plain-http address. That's a permanent, confirmed fact about
  /// this station, not something a retry would ever fix.
  static Future<String?> resolveStreamUrl(String stationId) async {
    try {
      final url = await _resolveStreamUrlRaw(stationId);
      if (url == null) return null;
      if (url.startsWith('https://')) throw const UnplayableStationException();
      return url;
    } on UnplayableStationException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Same resolve chain as [resolveStreamUrl], but returns the URL exactly
  /// as TuneIn reports it (http or https) with no rejection - for playback
  /// targets that genuinely can handle https directly, unlike the physical
  /// SoundTouch speaker's SetAVTransportURI (see resolveStreamUrl's own doc
  /// comment for why that one refuses https outright). "Stream on Your
  /// Phone" plays audio via just_audio, an ordinary HTTP(S) client with no
  /// such restriction, so it has no reason to exclude the (large) share of
  /// TuneIn stations that only serve https.
  static Future<String?> resolveStreamUrlForPhone(String stationId) async {
    try {
      return await _resolveStreamUrlRaw(stationId);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _resolveStreamUrlRaw(String stationId) async {
    final uri = Uri.parse(
      'https://opml.radiotime.com/Tune.ashx?id=${Uri.encodeQueryComponent(stationId)}&render=json',
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final body = (decoded['body'] as List?) ?? const [];
    if (body.isEmpty) return null;
    var url = (body.first as Map<String, dynamic>)['url'] as String?;
    if (url == null || url.isEmpty) return null;
    if (RegExp(r'\.(m3u|pls)(\?|$)').hasMatch(url)) {
      url = await _resolvePlaylistUrl(url);
    }
    return url;
  }

  static Future<String?> _resolvePlaylistUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      for (final line in response.body.split(RegExp(r'\r?\n'))) {
        final fileMatch = RegExp(r'^File\d*=(http.+)$').firstMatch(line);
        if (fileMatch != null) return fileMatch.group(1)!.trim();
        final bareMatch = RegExp(r'^\s*(https?://\S+)').firstMatch(line);
        if (bareMatch != null) return bareMatch.group(1)!.trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
