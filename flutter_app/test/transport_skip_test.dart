import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/search_result.dart';
import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/xml_api_client.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

/// SpeakerController.transportSkip is the plain transport row's Previous/Next
/// - it must step through the CURRENT radioResults list (wrapping
/// first<->last) when what's playing matches one of them, and otherwise fall
/// back to the generic PREV_TRACK/NEXT_TRACK device key. Driven through a
/// real FakeSpeakerServer (real SOAP play + XML poll round trips), not by
/// hand-setting nowPlaying, so a match/mismatch in how the stream URL is
/// built would show up here the same way it would against a real speaker.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late FakeSpeakerServer speaker;
  late SpeakerController controller;
  late SpeakerSession session;
  const ip = '127.0.0.30';
  const deviceId = 'transport-skip-test';

  Future<void> setUpSpeaker() async {
    speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Test Speaker');
    await speaker.start();
    controller = SpeakerController();
    // Fast, deterministic fake instead of a real TuneIn API call for a
    // made-up station id - see SpeakerController.resolveRadioUrl's doc
    // comment.
    controller.resolveRadioUrl = (stationId) async => 'http://stream.example/radio/$stationId.mp3';
    session = SpeakerSession(SpeakerInfo(ip: ip, deviceId: deviceId, name: 'Test Speaker'));
    controller.sessions = [session];
  }

  Future<void> pollNowPlaying() async {
    session.nowPlaying = await XmlApiClient.getNowPlaying(ip);
  }

  tearDown(() async {
    await speaker.stop();
  });

  test('applies wraparound logic to radio results', () async {
    await setUpSpeaker();
    controller.radioResults = const [
      RadioResult(name: 'Station 1', id: 's111'),
      RadioResult(name: 'Station 2', id: 's222'),
    ];

    await controller.playRadioResult(session, controller.radioResults[0]);
    await pollNowPlaying();

    await controller.transportSkip(session, -1);
    await pollNowPlaying();

    expect(session.nowPlaying?.location, contains('s222'));
  });

  test('steps from the first radio result forward to the second on Next', () async {
    await setUpSpeaker();
    controller.radioResults = const [
      RadioResult(name: 'Station 1', id: 's111'),
      RadioResult(name: 'Station 2', id: 's222'),
    ];

    await controller.playRadioResult(session, controller.radioResults[0]);
    await pollNowPlaying();

    await controller.transportSkip(session, 1);
    await pollNowPlaying();

    expect(session.nowPlaying?.location, contains('s222'));
  });

  test('falls back to the plain device key and leaves playback untouched when nothing matches a search result', () async {
    await setUpSpeaker();
    controller.radioResults = const [RadioResult(name: 'Station 1', id: 's111')];
    // Simulate a native/AUX source that isn't from the results list.
    await XmlApiClient.selectSource(ip, 'AUX');
    await pollNowPlaying();
    final locationBefore = session.nowPlaying?.location;

    await controller.transportSkip(session, 1);
    await pollNowPlaying();

    expect(session.nowPlaying?.location, locationBefore);
  });
}
