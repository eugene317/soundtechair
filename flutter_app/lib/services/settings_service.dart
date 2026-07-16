import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/speaker_info.dart';

/// Thin shared_preferences wrapper for the two server URLs and the last-known
/// speaker (so subsequent app opens can fast-path-verify instead of rescanning).
class SettingsService {
  static const _keySearchServerUrl = 'searchServerUrl';
  static const _keyStreamProxyUrl = 'streamProxyUrl';
  static const _keySpeakerIp = 'speakerIp';
  static const _keySpeakerName = 'speakerName';
  static const _keySpeakerDeviceId = 'speakerDeviceId';

  // Seeded with the currently-live tunnel URLs so onboarding isn't blank on
  // first run. These are ephemeral cloudflared quick-tunnel hosts and WILL
  // need to be updated from Settings whenever a tunnel restarts.
  static const defaultSearchServerUrl = 'https://promptly-ribbon-aging-affiliate.trycloudflare.com';
  static const defaultStreamProxyUrl = 'https://advisor-region-nearby-consists.trycloudflare.com';

  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      searchServerUrl: prefs.getString(_keySearchServerUrl) ?? defaultSearchServerUrl,
      streamProxyUrl: prefs.getString(_keyStreamProxyUrl) ?? defaultStreamProxyUrl,
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySearchServerUrl, settings.searchServerUrl);
    await prefs.setString(_keyStreamProxyUrl, settings.streamProxyUrl);
  }

  Future<bool> hasCompletedOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_keySearchServerUrl) || prefs.containsKey(_keyStreamProxyUrl);
  }

  Future<SpeakerInfo?> loadCachedSpeaker() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_keySpeakerIp);
    if (ip == null) return null;
    return SpeakerInfo(
      ip: ip,
      name: prefs.getString(_keySpeakerName) ?? 'Bose SoundTouch',
      deviceId: prefs.getString(_keySpeakerDeviceId) ?? '',
    );
  }

  Future<void> saveSpeaker(SpeakerInfo speaker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySpeakerIp, speaker.ip);
    await prefs.setString(_keySpeakerName, speaker.name);
    await prefs.setString(_keySpeakerDeviceId, speaker.deviceId);
  }

  Future<void> clearCachedSpeaker() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySpeakerIp);
    await prefs.remove(_keySpeakerName);
    await prefs.remove(_keySpeakerDeviceId);
  }
}
