import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/soap_client.dart';
import 'package:soundtech_air/services/xml_api_client.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

/// A preset saved via the speaker's own PHYSICAL hold-to-save button (which
/// the app has no direct signal for - it can only ever find out by polling
/// /presets) must show up in the app on the next regular poll, not stay
/// stale until the next reconnect. Simulates a "physical" save by calling
/// XmlApiClient.saveToPreset directly against the fake server - the SAME
/// client code a real physical hold ultimately drives on the device side -
/// without going through the controller's own savePreset at all, so this
/// only passes if refreshStatus itself independently re-fetches presets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const ip = '127.0.0.32';
  const deviceId = 'preset-poll-test';

  test('refreshStatus picks up a preset saved outside the app (simulating a physical hold-to-save)', () async {
    final speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Test Speaker');
    await speaker.start();
    try {
      final controller = SpeakerController();
      final session = SpeakerSession(SpeakerInfo(ip: ip, deviceId: deviceId, name: 'Test Speaker'));
      controller.sessions = [session];

      expect(session.presets['1'], isNull);

      // Play something, then "physically" save it to preset 1 - bypassing
      // controller.savePreset entirely, so the app's session.presets map has
      // no way to know about this yet, exactly like a real physical hold.
      await SoapClient.play(ip, 'http://example.com/radio.mp3', title: 'Radio X');
      await XmlApiClient.saveToPreset(ip, '1');

      await controller.refreshStatus(session);

      expect(session.presets['1']?.contentItemLocation, 'http://example.com/radio.mp3');
    } finally {
      await speaker.stop();
    }
  });
}
