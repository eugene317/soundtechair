import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/models/search_result.dart';
import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/xml_api_client.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

/// SpeakerController.isPlayingRadio drives the player card's shortcut strip
/// and source-indicator label - it must correctly identify whether the
/// CURRENTLY PLAYING location matches a known TuneIn result. Driven through
/// a real FakeSpeakerServer, same pattern as transport_skip_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late FakeSpeakerServer speaker;
  late SpeakerController controller;
  late SpeakerSession session;
  const ip = '127.0.0.31';
  const deviceId = 'current-playing-source-test';

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

  test('identifies radio as the current source when a TuneIn result is playing', () async {
    await setUpSpeaker();
    controller.radioResults = const [RadioResult(name: 'Station 1', id: 's111')];

    await controller.playRadioResult(session, controller.radioResults[0]);
    await pollNowPlaying();

    expect(controller.isPlayingRadio(session), isTrue);
  });

  test('returns false when nothing is playing from the known results list', () async {
    await setUpSpeaker();
    controller.radioResults = const [RadioResult(name: 'Station 1', id: 's111')];
    await XmlApiClient.selectSource(ip, 'AUX');
    await pollNowPlaying();

    expect(controller.isPlayingRadio(session), isFalse);
  });

  test('returns false when nothing is playing at all', () async {
    await setUpSpeaker();
    controller.radioResults = const [RadioResult(name: 'Station 1', id: 's111')];
    await pollNowPlaying();

    expect(controller.isPlayingRadio(session), isFalse);
  });
}
