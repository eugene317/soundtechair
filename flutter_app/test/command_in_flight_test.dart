import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/xml_api_client.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

/// A physical SoundTouch 10's AVTransport service was directly observed
/// (manual curl testing against the real device) accepting two overlapping
/// SetAVTransportURI/Play or /key press+release sequences with HTTP 200
/// each, then never actually applying either one - a device-side
/// concurrency issue triggered by two commands racing on the wire for the
/// same session. SpeakerSession.commandInFlight exists specifically to stop
/// this app from ever being the source of that overlap: a second command
/// for a session that already has one in flight is dropped outright rather
/// than raced. Verified here via the SAME observable side effect a real
/// overlap would have caused - if the guard didn't work, firing two POWER
/// toggles concurrently would toggle the (fake) device's power state twice
/// (ending back off); if it works, only the first one lands.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const ip = '127.0.0.33';
  const deviceId = 'command-in-flight-test';

  test('a second overlapping sendKey call for the same session is dropped, not raced', () async {
    final speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Test Speaker');
    await speaker.start();
    try {
      final controller = SpeakerController();
      final session = SpeakerSession(SpeakerInfo(ip: ip, deviceId: deviceId, name: 'Test Speaker'));
      controller.sessions = [session];

      final before = await XmlApiClient.getNowPlaying(ip);
      expect(before.isOn, false);

      // Fire two POWER toggles without awaiting the first - if
      // commandInFlight didn't stop the second, the device would see BOTH
      // toggles (off -> on -> off again); if it works, only the first reaches
      // the device.
      final first = controller.sendKey(session, 'POWER');
      final second = controller.sendKey(session, 'POWER');
      await Future.wait([first, second]);

      final after = await XmlApiClient.getNowPlaying(ip);
      expect(after.isOn, true);
      expect(session.commandInFlight, false);
    } finally {
      await speaker.stop();
    }
  });
}
