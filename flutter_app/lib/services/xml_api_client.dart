import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/group_info.dart';
import '../models/now_playing.dart';
import '../models/preset_slot.dart';
import '../models/speaker_info.dart';
import '../models/volume_status.dart';
import '../models/zone_info.dart';

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

  /// Long-press-to-save: repeated press, then release. Confirmed against
  /// real hardware (2026-07-28) that a SINGLE press followed by silence for
  /// several seconds is NOT equivalent to a genuine physical hold, even
  /// though it looked like it should be: a single-press-then-wait hold (both
  /// 3s and 6s were tried) got GET /presets (and this app's own in-app
  /// recall) to correctly reflect the new save, but the speaker's PHYSICAL
  /// preset button still ignored it entirely - direct manual testing with
  /// curl-equivalent /key calls (bypassing this app's Dart code completely)
  /// reproduced the identical split, proving it wasn't a bug in this app's
  /// implementation at all. What actually fixed it: sending "press" AGAIN
  /// periodically for the whole hold, instead of one press then dead air -
  /// confirmed via the same direct manual testing that THIS is what a real
  /// physical hold's button-facing commit needs (a real hardware hold
  /// presumably re-asserts "still held" continuously at the GPIO level,
  /// which the software/network layer apparently tolerates being silent
  /// for, but the physical button's own persistent-storage commit does not).
  /// The original PowerShell script this was first ported from never
  /// re-asserted press either - it just used a single press + Start-Sleep -
  /// so this repeated-press behavior is new, not a restoration of prior
  /// behavior.
  ///
  /// Re-press interval is 2s (3 presses over the 6s hold), not 1s (which
  /// works too, but re-triggers the speaker's own audible "still holding"
  /// confirmation tone on every single re-press - 6 tones for a 1s interval
  /// vs. 3 for 2s, confirmed by field-testing both against real hardware,
  /// 2026-07-28). A real physical hold only ever makes ONE tone, since
  /// mechanically it's a single continuous contact-closure with no repeated
  /// "press" edge for the firmware to re-fire the tone on - this network
  /// simulation can't avoid re-triggering it at least once more without
  /// losing the physical-button save entirely, but widening the interval
  /// keeps it down to a tolerable 3 instead of 6.
  static Future<void> saveToPreset(String speakerIp, String presetNum) async {
    final key = 'PRESET_$presetNum';
    const pressCount = 3;
    for (var i = 0; i < pressCount; i++) {
      await _post(speakerIp, '/key', '<key state="press" sender="Gabbo">$key</key>');
      await Future.delayed(const Duration(seconds: 2));
    }
    await _post(speakerIp, '/key', '<key state="release" sender="Gabbo">$key</key>');
  }

  static Future<void> setVolume(String speakerIp, int level) async {
    await _post(speakerIp, '/volume', '<volume>$level</volume>');
  }

  /// L/R balance for a stereo pair, -50 (full left) to +50 (full right), 0 =
  /// center. Write-only on real hardware - there is no GET /balance to read
  /// the current value back, unlike volume.
  static Future<void> setBalance(String speakerIp, int value) async {
    await _post(speakerIp, '/balance', '<balance><targetBalance>$value</targetBalance></balance>');
  }

  /// Only two branches exist in the original: BLUETOOTH, or everything else
  /// (including "AUX") falls through to AUX - preserved here intentionally.
  static Future<void> selectSource(String speakerIp, String source) async {
    final body = source == 'BLUETOOTH'
        ? '<ContentItem source="BLUETOOTH" sourceAccount="" isPresetable="false"><itemName>Bluetooth</itemName></ContentItem>'
        : '<ContentItem source="AUX" sourceAccount="AUX" isPresetable="false"><itemName>AUX IN</itemName></ContentItem>';
    await _post(speakerIp, '/select', body);
  }

  /// EXPERIMENTAL - UNVERIFIED against real hardware as of 2026-08-15.
  ///
  /// A radio stream is normally started via SoapClient.play, which talks to
  /// the generic UPnP AVTransport service directly - never through this
  /// SoundTouch-specific ContentItem/source system at all (unlike the
  /// official Bose app's own TuneIn integration, which presumably selects
  /// stations through exactly this /select mechanism, with its own embedded
  /// TuneIn client resolving the actual stream itself). AUX/BLUETOOTH above
  /// are explicitly marked isPresetable="false" - real, confirmed SoundTouch
  /// behavior - which strongly suggests physical hold-to-save reads its
  /// "can I save this?" answer from THIS registry, not from whatever the
  /// generic AVTransport layer happens to be playing underneath. Reported
  /// field symptom this is meant to address: saving a radio station to a
  /// preset from within the app appears to succeed (round-trips through GET
  /// /presets, plays back fine from the app), but holding the SAME preset
  /// button physically on the speaker rejects it (amber/orange blink) -
  /// consistent with the physical button validating against a ContentItem
  /// registry that a bare SetAVTransportURI call never touches.
  ///
  /// This attempts to also register the stream here, isPresetable="true",
  /// BEFORE SoapClient.play runs (see playRadioResult) - real SoundTouch
  /// INTERNET_RADIO ContentItems normally carry an internal TuneIn-resolved
  /// location token, not an arbitrary raw HTTP URL, so the device may
  /// reject this outright, silently ignore it, or (worst case) briefly try
  /// to act on it. Deliberately called and allowed to fail BEFORE, not
  /// after, the real play call - so whatever this does or doesn't do, the
  /// proven-working SetAVTransportURI/Play sequence right after it is what
  /// actually determines final playback state. Every caller must swallow
  /// failures from this (see SpeakerController's caller) - this must never
  /// block or break real playback starting.
  static Future<void> registerPresetableStream(String speakerIp, String url, String name) async {
    final body = '<ContentItem source="INTERNET_RADIO" location="${_escapeXml(url)}" sourceAccount="" isPresetable="true">'
        '<itemName>${_escapeXml(name)}</itemName></ContentItem>';
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
      name: nameEl.isEmpty ? 'Unnamed Speaker' : nameEl.first.innerText,
    );
  }

  /// Renames the speaker itself (a real SoundTouch WebServices endpoint, same
  /// device-level rename the official Bose app's own "Edit Name" does) -
  /// deliberately NOT a local-only override, so the new name shows up
  /// everywhere (this app, the official app, any other UPnP client) and
  /// naturally survives every future /info poll with no extra bookkeeping.
  static Future<void> setName(String speakerIp, String name) async {
    await _post(speakerIp, '/name', '<name>${_escapeXml(name)}</name>');
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

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

  // --- Stereo pairing ("group") - a different feature from the plain
  // multi-room zone API (no L/R concept there). Confirmed against a real
  // SoundTouch 10 (2026-07-18): GET /getGroup returns 200 with "<group />"
  // when unpaired - GET /group (this constant's original guess, based on
  // ambiguous secondhand documentation) 404s on real hardware.
  static const _groupPath = '/getGroup';

  /// Null for "not currently paired" (empty/malformed `<group>` response).
  /// Network/HTTP errors are NOT caught here (unlike GroupInfo.fromXmlString's
  /// own parse-error handling) - they propagate so callers can distinguish
  /// "polled fine, no active pairing" from "couldn't reach this endpoint at
  /// all", which matters for gating the pairing UI on real capability.
  static Future<GroupInfo?> getGroup(String speakerIp) async {
    final raw = await get(speakerIp, _groupPath);
    return GroupInfo.fromXmlString(raw);
  }

  static Future<void> addGroup(String speakerIp, {required String masterDeviceId, required List<GroupRole> roles, String? name}) async {
    final rolesXml = roles
        .map((r) =>
            '<groupRole><deviceId>${r.deviceId}</deviceId><role>${r.role == StereoRole.left ? 'LEFT' : 'RIGHT'}</role><ipAddress>${r.ipAddress}</ipAddress></groupRole>')
        .join();
    final body = '<group><name>${name ?? ''}</name><masterDeviceId>$masterDeviceId</masterDeviceId><roles>$rolesXml</roles></group>';
    await _post(speakerIp, '/addGroup', body);
  }

  static Future<void> removeGroup(String speakerIp) async {
    await get(speakerIp, '/removeGroup');
  }

  // --- Multi-room "Zone" grouping - see ZoneInfo's own doc comment for how
  // this differs from stereo "group" pairing above, and for why the exact
  // paths/body shape below are UNCONFIRMED against real hardware (same
  // "documented, but verify" status /getGroup itself started from). Every
  // mutation is sent to the MASTER's IP, per the documented SoundTouch
  // WebServices shape - a slave never accepts these directly.
  static Future<ZoneInfo?> getZone(String speakerIp) async {
    final raw = await get(speakerIp, '/getZone');
    return ZoneInfo.fromXmlString(raw);
  }

  static String _zoneMembersXml(List<ZoneMember> members) =>
      members.map((m) => '<member ipaddress="${m.ipAddress}">${m.deviceId}</member>').join();

  /// Creates a brand-new zone. [members] must include the master itself (as
  /// its own ZoneMember) alongside every slave - the documented shape always
  /// lists the master as a member of its own zone.
  static Future<void> setZone(String masterIp, {required String masterDeviceId, required List<ZoneMember> members}) async {
    final body = '<zone master="$masterDeviceId">${_zoneMembersXml(members)}</zone>';
    await _post(masterIp, '/setZone', body);
  }

  /// Adds one or more slaves to an EXISTING zone - [newSlaves] here is just
  /// the new members being added, not the master or the zone's existing
  /// membership (unlike [setZone]'s full-membership body).
  static Future<void> addZoneSlave(String masterIp, {required String masterDeviceId, required List<ZoneMember> newSlaves}) async {
    final body = '<zone master="$masterDeviceId">${_zoneMembersXml(newSlaves)}</zone>';
    await _post(masterIp, '/addZoneSlave', body);
  }

  /// Removes one or more slaves from a zone - same "just the ones changing"
  /// body shape as [addZoneSlave]. Removing every slave and the master
  /// itself dissolves the whole zone (no separate "remove entire zone"
  /// endpoint is documented).
  static Future<void> removeZoneSlave(String masterIp, {required String masterDeviceId, required List<ZoneMember> slaves}) async {
    final body = '<zone master="$masterDeviceId">${_zoneMembersXml(slaves)}</zone>';
    await _post(masterIp, '/removeZoneSlave', body);
  }
}
