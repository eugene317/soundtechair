import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/search_result.dart';
import '../models/speaker_info.dart';

/// Thin shared_preferences wrapper for the last-known speakers (so
/// subsequent app opens can fast-path-verify instead of rescanning) plus a
/// couple of small UI preferences.
class SettingsService {
  static const _keySpeakers = 'speakers';
  static const _keyOpenRemoteByDefault = 'openRemoteByDefault';
  static const _keyLastRemoteDesignIndex = 'lastRemoteDesignIndex';
  static const _keyRecentlyPlayed = 'recentlyPlayedRadio';
  static const _keyFavorites = 'favoriteRadioStations';

  // Legacy single-speaker keys from before multi-speaker support - no longer
  // written, but still read once by loadCachedSpeakers() to migrate an
  // already-installed app's remembered speaker into the new list-shaped key
  // instead of silently losing it.
  static const _keyLegacySpeakerIp = 'speakerIp';
  static const _keyLegacySpeakerName = 'speakerName';
  static const _keyLegacySpeakerDeviceId = 'speakerDeviceId';

  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      openRemoteByDefault: prefs.getBool(_keyOpenRemoteByDefault) ?? false,
      lastRemoteDesignIndex: prefs.getInt(_keyLastRemoteDesignIndex) ?? 0,
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOpenRemoteByDefault, settings.openRemoteByDefault);
    await prefs.setInt(_keyLastRemoteDesignIndex, settings.lastRemoteDesignIndex);
  }

  Future<List<SpeakerInfo>> loadCachedSpeakers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySpeakers);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      return list.map((e) => SpeakerInfo.fromJson(e as Map<String, dynamic>)).toList();
    }
    // One-time migration: an already-installed app remembers at most one
    // speaker under the old flat scalar keys - seed the new list from it
    // instead of silently losing it. Old keys are left in place; nothing
    // else reads them anymore.
    final legacyIp = prefs.getString(_keyLegacySpeakerIp);
    if (legacyIp == null) return [];
    return [
      SpeakerInfo(
        ip: legacyIp,
        name: prefs.getString(_keyLegacySpeakerName) ?? 'Unnamed Speaker',
        deviceId: prefs.getString(_keyLegacySpeakerDeviceId) ?? '',
      ),
    ];
  }

  Future<void> saveSpeakers(List<SpeakerInfo> speakers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySpeakers, jsonEncode(speakers.map((s) => s.toJson()).toList()));
  }

  Future<void> clearCachedSpeakers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySpeakers);
    await prefs.remove(_keyLegacySpeakerIp);
    await prefs.remove(_keyLegacySpeakerName);
    await prefs.remove(_keyLegacySpeakerDeviceId);
  }

  Future<List<RadioResult>> loadRecentlyPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyRecentlyPlayed);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => RadioResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveRecentlyPlayed(List<RadioResult> results) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyRecentlyPlayed, jsonEncode(results.map((r) => r.toJson()).toList()));
  }

  /// User-curated favorites - unlike a device preset slot, this is purely
  /// local app data with no speaker-side write involved at all, so it's
  /// always reliable (see SpeakerController.toggleFavorite's own doc comment
  /// for why this exists alongside, not instead of, the physical presets).
  Future<List<RadioResult>> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFavorites);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => RadioResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveFavorites(List<RadioResult> results) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFavorites, jsonEncode(results.map((r) => r.toJson()).toList()));
  }
}
