import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/now_playing.dart';
import '../models/preset_slot.dart';
import '../models/speaker_info.dart';
import '../models/volume_status.dart';

/// Local XML API on port 8090, ported 1:1 from SoundTouch-Common.ps1's
/// Send-SoundTouchKey / Set-SoundTouchVolume / Select-Source / Get-SoundTouchEndpoint /
/// Save-CurrentToPreset / Get-PresetUrl.
class XmlApiClient {
  static const _shortTimeout = Duration(seconds: 5);

  static Future<void> _post(String speakerIp, String path, String body) async {
    final uri = Uri.parse('http://$speakerIp:8090$path');
    final response = await http
        .post(uri, headers: {'Content-Type': 'text/xml'}, body: utf8.encode(body))
        .timeout(_shortTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('POST $path failed: HTTP ${response.statusCode}');
    }
  }

  static Future<String> get(String speakerIp, String path) async {
    final uri = Uri.parse('http://$speakerIp:8090$path');
    final response = await http.get(uri).timeout(_shortTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('GET $path failed: HTTP ${response.statusCode}');
    }
    return response.body;
  }

  /// Sends a normal key press+release pair (PLAY, PAUSE, POWER, PREV_TRACK,
  /// NEXT_TRACK, PRESET_1..PRESET_6, VOLUME_UP, VOLUME_DOWN, etc.), sequentially,
  /// no delay - a fast tap/recall, not a hold-to-save.
  static Future<void> sendKey(String speakerIp, String key) async {
    await _post(speakerIp, '/key', '<key state="press" sender="Gabbo">$key</key>');
    await _post(speakerIp, '/key', '<key state="release" sender="Gabbo">$key</key>');
  }

  /// Long-press-to-save: press, hold 3 real seconds, release. This 3s gap is
  /// what makes the firmware interpret it as "save current" instead of "recall".
  static Future<void> saveToPreset(String speakerIp, String presetNum) async {
    final key = 'PRESET_$presetNum';
    await _post(speakerIp, '/key', '<key state="press" sender="Gabbo">$key</key>');
    await Future.delayed(const Duration(seconds: 3));
    await _post(speakerIp, '/key', '<key state="release" sender="Gabbo">$key</key>');
  }

  static Future<void> setVolume(String speakerIp, int level) async {
    await _post(speakerIp, '/volume', '<volume>$level</volume>');
  }

  /// Only two branches exist in the original: BLUETOOTH, or everything else
  /// (including "AUX") falls through to AUX - preserved here intentionally.
  static Future<void> selectSource(String speakerIp, String source) async {
    final body = source == 'BLUETOOTH'
        ? '<ContentItem source="BLUETOOTH" sourceAccount="" isPresetable="false"><itemName>Bluetooth</itemName></ContentItem>'
        : '<ContentItem source="AUX" sourceAccount="AUX" isPresetable="false"><itemName>AUX IN</itemName></ContentItem>';
    await _post(speakerIp, '/select', body);
  }

  static Future<SpeakerInfo> getInfo(String speakerIp) async {
    final raw = await get(speakerIp, '/info');
    final doc = XmlDocument.parse(raw);
    final root = doc.rootElement;
    final nameEl = root.findElements('name');
    return SpeakerInfo(
      ip: speakerIp,
      deviceId: root.getAttribute('deviceID') ?? '',
      name: nameEl.isEmpty ? 'Bose SoundTouch' : nameEl.first.innerText,
    );
  }

  static Future<NowPlaying> getNowPlaying(String speakerIp) async {
    final raw = await get(speakerIp, '/now_playing');
    return NowPlaying.fromXmlString(raw);
  }

  static Future<VolumeStatus> getVolumeStatus(String speakerIp) async {
    final raw = await get(speakerIp, '/volume');
    return VolumeStatus.fromXmlString(raw);
  }

  static Future<Map<String, PresetSlot>> getPresets(String speakerIp) async {
    final raw = await get(speakerIp, '/presets');
    return PresetSlot.listFromXmlString(raw);
  }

  static Future<String?> getPresetUrl(String speakerIp, String presetNum) async {
    final presets = await getPresets(speakerIp);
    return presets[presetNum]?.contentItemLocation;
  }
}
