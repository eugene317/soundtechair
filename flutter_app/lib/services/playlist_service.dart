import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';

/// shared_preferences JSON persistence for the whole playlist library, same
/// "load once, write the whole thing back on every change" pattern as
/// SettingsService - no database, since this is one user's personal library
/// (tens of playlists, tens-to-hundreds of tracks each, edited only on
/// explicit user action) not a scale problem a database would help with.
class PlaylistService {
  static const _key = 'playlists';
  static const _currentVersion = 1;

  Future<List<Playlist>> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final rawPlaylists = (decoded['playlists'] as List?) ?? const [];
      return rawPlaylists
          .map((p) => Playlist.fromJson(Map<String, dynamic>.from(p as Map)))
          .whereType<Playlist>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePlaylists(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'version': _currentVersion,
      'playlists': playlists.map((p) => p.toJson()).toList(),
    });
    await prefs.setString(_key, payload);
  }
}
