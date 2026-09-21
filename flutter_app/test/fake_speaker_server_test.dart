import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/group_info.dart';
import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/soap_client.dart';
import 'package:soundtech_air/services/xml_api_client.dart';

/// Drives the fake speaker with the SAME client code (XmlApiClient/
/// SoapClient) used against a real device - not a mock of a mock. If these
/// pass, the fake server's XML/SOAP responses are provably shaped exactly
/// the way the real app's parsers expect, not just "shaped how I assumed".
void main() {
  group('FakeSpeakerServer via the real XmlApiClient/SoapClient', () {
    late FakeSpeakerServer speaker;
    const ip = '127.0.0.9';
    const deviceId = 'fake-test-1';

    setUp(() async {
      speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Fake Test Speaker');
      await speaker.start();
    });

    tearDown(() async {
      await speaker.stop();
    });

    test('getInfo returns the configured name/deviceId', () async {
      final info = await XmlApiClient.getInfo(ip);
      expect(info.deviceId, deviceId);
      expect(info.name, 'Fake Test Speaker');
    });

    test('fresh speaker reports standby (not "on"), not playing', () async {
      final np = await XmlApiClient.getNowPlaying(ip);
      expect(np.isOn, false);
      expect(np.isPlaying, false);
    });

    test('sendKey PLAY/PAUSE toggles playStatus seen by getNowPlaying', () async {
      await XmlApiClient.sendKey(ip, 'POWER'); // power on first (selects AUX)
      var np = await XmlApiClient.getNowPlaying(ip);
      expect(np.isOn, true);

      await XmlApiClient.sendKey(ip, 'PLAY');
      np = await XmlApiClient.getNowPlaying(ip);
      expect(np.isPlaying, true);

      await XmlApiClient.sendKey(ip, 'PAUSE');
      np = await XmlApiClient.getNowPlaying(ip);
      expect(np.isPlaying, false);
    });

    test('setVolume is reflected by getVolumeStatus', () async {
      await XmlApiClient.setVolume(ip, 42);
      final vol = await XmlApiClient.getVolumeStatus(ip);
      expect(vol.actual, 42);
    });

    test('selectSource(AUX) is parsed from the real <ContentItem source="AUX"> body, not a bare string', () async {
      await XmlApiClient.selectSource(ip, 'AUX');
      final np = await XmlApiClient.getNowPlaying(ip);
      expect(np.source, 'AUX');
      expect(np.isOn, true);
    });

    test('SoapClient.play with title+duration is visible via getNowPlaying after the real double-escaped DIDL-Lite round trip', () async {
      await SoapClient.play(
        ip,
        'http://example.com/stream.mp3',
        title: 'My Test Track',
        duration: const Duration(minutes: 3, seconds: 30),
      );
      final np = await XmlApiClient.getNowPlaying(ip);
      expect(np.hasKnownDuration, true);
      expect(np.totalSeconds, 210);
      expect(np.track, 'My Test Track');
      // SoapClient.play issues Play as a second SOAP call right after
      // SetAVTransportURI, so by the time it returns, playback has started.
      expect(np.isPlaying, true);
    });

    test('a title with an apostrophe, ampersand and quote survives the double-escaped DIDL-Lite round trip intact', () async {
      // Regression test: a naive regex extraction over the once-decoded DIDL
      // metadata leaves entities from the SECOND (DIDL-level) escaping layer
      // undecoded - e.g. "Rock & Roll" would come back as "Rock &amp; Roll".
      // Real titles routinely contain all of these characters.
      await SoapClient.play(
        ip,
        'http://example.com/stream.mp3',
        title: '''Rock & Roll "Ain't" <Dead> — Vol. 1''',
      );
      final np = await XmlApiClient.getNowPlaying(ip);
      expect(np.track, '''Rock & Roll "Ain't" <Dead> — Vol. 1''');
    });

    test('SoapClient.stop clears playing state', () async {
      await SoapClient.play(ip, 'http://example.com/stream.mp3', title: 'X');
      await SoapClient.stop(ip);
      final np = await XmlApiClient.getNowPlaying(ip);
      expect(np.isPlaying, false);
    });

    test('a short PRESET_1 tap with nothing saved does nothing (no crash, empty presets)', () async {
      await XmlApiClient.sendKey(ip, 'PRESET_1');
      final presets = await XmlApiClient.getPresets(ip);
      expect(presets.isEmpty, true);
    });

    test('saveToPreset (real 3s hold) then playPreset round-trips through getPresets', () async {
      await SoapClient.play(ip, 'http://example.com/radio.mp3', title: 'Radio X');
      await XmlApiClient.saveToPreset(ip, '1');
      final presets = await XmlApiClient.getPresets(ip);
      expect(presets['1']?.contentItemLocation, 'http://example.com/radio.mp3');

      final url = await XmlApiClient.getPresetUrl(ip, '1');
      expect(url, 'http://example.com/radio.mp3');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('getGroup on an unpaired fake speaker is null', () async {
      final group = await XmlApiClient.getGroup(ip);
      expect(group, null);
    });
  });

  group('Stereo pairing between two fake speakers, driven by the real XmlApiClient', () {
    late FakeSpeakerServer left;
    late FakeSpeakerServer right;
    const leftIp = '127.0.0.10';
    const rightIp = '127.0.0.11';
    const leftId = 'fake-left';
    const rightId = 'fake-right';

    setUp(() async {
      left = FakeSpeakerServer(ip: leftIp, deviceId: leftId, name: 'Left Speaker');
      right = FakeSpeakerServer(ip: rightIp, deviceId: rightId, name: 'Right Speaker');
      await left.start();
      await right.start();
    });

    tearDown(() async {
      await left.stop();
      await right.stop();
    });

    test('addGroup makes BOTH sides report the pairing back (mutual reciprocity)', () async {
      await XmlApiClient.addGroup(
        leftIp,
        masterDeviceId: leftId,
        roles: [
          GroupRole(deviceId: leftId, role: StereoRole.left, ipAddress: leftIp),
          GroupRole(deviceId: rightId, role: StereoRole.right, ipAddress: rightIp),
        ],
        name: 'Test Pair',
      );

      final leftGroup = await XmlApiClient.getGroup(leftIp);
      final rightGroup = await XmlApiClient.getGroup(rightIp);

      expect(leftGroup, isNotNull);
      expect(rightGroup, isNotNull);
      expect(leftGroup!.masterDeviceId, leftId);
      expect(rightGroup!.masterDeviceId, leftId);
      // Each side's roles list must name the OTHER device back, or
      // SpeakerController.playbackTargets' mutual-reciprocity check would
      // refuse to merge them into one card.
      expect(leftGroup.roles.any((r) => r.deviceId == rightId), true);
      expect(rightGroup.roles.any((r) => r.deviceId == leftId), true);
    });

    test('removeGroup clears the pairing on both sides', () async {
      await XmlApiClient.addGroup(
        leftIp,
        masterDeviceId: leftId,
        roles: [
          GroupRole(deviceId: leftId, role: StereoRole.left, ipAddress: leftIp),
          GroupRole(deviceId: rightId, role: StereoRole.right, ipAddress: rightIp),
        ],
      );
      await XmlApiClient.removeGroup(leftIp);

      expect(await XmlApiClient.getGroup(leftIp), null);
      expect(await XmlApiClient.getGroup(rightIp), null);
    });
  });
}
