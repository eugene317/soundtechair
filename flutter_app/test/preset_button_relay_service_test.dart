import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/services/fake_speaker_server.dart';
import 'package:soundtech_air/services/preset_button_relay_service.dart';
import 'package:soundtech_air/services/xml_api_client.dart';

/// Verifies the in-app physical-preset-button relay end to end against a
/// real (loopback) WebSocket + SOAP server - the same real network code
/// paths a genuine SoundTouch speaker's notification socket and AVTransport
/// control endpoint would drive, not a mocked stream. This is the Dart-side
/// equivalent of what preset-listener.ps1 does for the PC backend: catch a
/// physical preset-button press over the speaker's own notification
/// WebSocket, then replay it via SetAVTransportURI + Play.
Future<void> _waitUntil(FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!(await condition())) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const ip = '127.0.0.34';
  const deviceId = 'preset-relay-test';

  test('a physical preset-button press notification triggers a replay to the same location', () async {
    final speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Test Speaker');
    await speaker.start();
    final relay = PresetButtonRelayService(ip);
    try {
      relay.start();
      // Give the WebSocket a moment to actually establish before the
      // "press" fires - a message sent before any client is connected has
      // nothing to deliver it to.
      await Future.delayed(const Duration(milliseconds: 200));

      await speaker.simulatePresetButtonPress('1', location: 'http://example.com/radio.mp3');

      // The replay goes through two async SOAP calls (Stop, then
      // SetAVTransportURI+Play) after the WS message arrives, so poll
      // rather than asserting immediately.
      await _waitUntil(() async {
        final now = await XmlApiClient.getNowPlaying(ip);
        return now.location == 'http://example.com/radio.mp3' && now.isPlaying;
      });
    } finally {
      relay.stop();
      await speaker.stop();
    }
  });

  test('a duplicate notification for the same preset within the dedup window is not replayed twice', () async {
    final speaker = FakeSpeakerServer(ip: ip, deviceId: deviceId, name: 'Test Speaker');
    await speaker.start();
    final relay = PresetButtonRelayService(ip);
    try {
      relay.start();
      await Future.delayed(const Duration(milliseconds: 200));

      await speaker.simulatePresetButtonPress('1', location: 'http://example.com/radio.mp3');
      await _waitUntil(() async {
        final now = await XmlApiClient.getNowPlaying(ip);
        return now.location == 'http://example.com/radio.mp3' && now.isPlaying;
      });

      // Manually stop playback, then send the SAME notification again
      // immediately - a real speaker's notification socket has been
      // observed emitting more than one nowSelectionUpdated for a single
      // physical press. If the dedup guard didn't work, this second
      // message would replay (and re-start) playback again.
      await XmlApiClient.sendKey(ip, 'PAUSE');
      await speaker.simulatePresetButtonPress('1', location: 'http://example.com/radio.mp3');
      await Future.delayed(const Duration(milliseconds: 300));

      final now = await XmlApiClient.getNowPlaying(ip);
      expect(now.isPlaying, false, reason: 'duplicate notification within the dedup window should have been ignored');
    } finally {
      relay.stop();
      await speaker.stop();
    }
  });
}
