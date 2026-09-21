import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:soundtech_air/services/bose_wifi_setup_service.dart';

/// Drives the real BoseWifiSetupService client code against a small fake
/// WebSocket server that speaks the same conversational contract a real
/// SoundTouch speaker does in setup mode (confirmed by decompiling the
/// official Bose app's APK, 2026-07-22) - so a mistake in the message
/// sequencing/substring matching fails here instead of only against a real
/// speaker in the field.
Future<HttpServer> _startFakeSetupSocket(String ip, void Function(WebSocket) onConnect) async {
  final server = await HttpServer.bind(ip, 8080);
  server.listen((request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      onConnect(ws);
    }
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('getDeviceId parses the deviceID attribute out of /info', () async {
    const ip = '127.0.0.30';
    final server = await HttpServer.bind(ip, 8090);
    final sub = server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.write('<info deviceID="ABC123" />');
      await request.response.close();
    });
    try {
      final id = await BoseWifiSetupService.getDeviceId(setupIp: ip);
      expect(id, 'ABC123');
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  });

  test('getDeviceId returns null when the setup-mode gateway is unreachable', () async {
    final id = await BoseWifiSetupService.getDeviceId(setupIp: '127.0.0.31');
    expect(id, null);
  });

  test('sendWifiCredentials completes true only after the speaker pushes NETWORK_WIFI_CONNECTED', () async {
    const ip = '127.0.0.32';
    final receivedMessages = <String>[];
    final server = await _startFakeSetupSocket(ip, (ws) {
      ws.listen((data) {
        final text = data as String;
        receivedMessages.add(text);
        if (text.contains('url="setup"') && text.contains('SETUP_START')) {
          ws.add('<msg>ack SETUP_START</msg>');
        } else if (text.contains('url="performWirelessSiteSurvey"')) {
          ws.add('<msg>PerformWirelessSiteSurveyResponse ok</msg>');
        } else if (text.contains('url="addWirelessProfile"')) {
          ws.add('<msg>AddWirelessProfileResponse ok</msg>');
          // A real speaker takes a moment to actually join before pushing
          // this - a tiny delay here catches a client that (wrongly)
          // assumes AddWirelessProfileResponse itself means success.
          Timer(const Duration(milliseconds: 30), () => ws.add('<msg>NETWORK_WIFI_CONNECTED</msg>'));
        }
      });
    });

    try {
      final statuses = <String>[];
      final result = await BoseWifiSetupService.sendWifiCredentials(
        deviceId: 'ABC123',
        homeSsid: 'HomeNet',
        homePassword: 'secret123',
        isOpenNetwork: false,
        setupIp: ip,
        onStatus: statuses.add,
      );

      expect(result.success, true);
      expect(statuses, contains('Speaker connected to your WiFi!'));
      // The credentials must actually be the ones sent - not a hard-coded
      // placeholder that happens to satisfy the state machine.
      expect(
        receivedMessages.any((m) => m.contains('ssid="HomeNet"') && m.contains('password="secret123"') && m.contains('securityType="wpa_or_wpa2"')),
        true,
      );
      // deviceID must be threaded through every message, not just the first.
      expect(receivedMessages.every((m) => m.contains('deviceID="ABC123"')), true);
    } finally {
      await server.close(force: true);
    }
  });

  test('sendWifiCredentials uses securityType="none" for an open home network', () async {
    const ip = '127.0.0.33';
    final receivedMessages = <String>[];
    final server = await _startFakeSetupSocket(ip, (ws) {
      ws.listen((data) {
        final text = data as String;
        receivedMessages.add(text);
        if (text.contains('SETUP_START')) {
          ws.add('<msg>ack SETUP_START</msg>');
        } else if (text.contains('url="performWirelessSiteSurvey"')) {
          ws.add('<msg>PerformWirelessSiteSurveyResponse ok</msg>');
        } else if (text.contains('url="addWirelessProfile"')) {
          ws.add('<msg>AddWirelessProfileResponse ok</msg>');
          ws.add('<msg>NETWORK_WIFI_CONNECTED</msg>');
        }
      });
    });

    try {
      final result = await BoseWifiSetupService.sendWifiCredentials(
        deviceId: 'ABC123',
        homeSsid: 'OpenNet',
        homePassword: '',
        isOpenNetwork: true,
        setupIp: ip,
      );
      expect(result.success, true);
      expect(receivedMessages.any((m) => m.contains('securityType="none"')), true);
    } finally {
      await server.close(force: true);
    }
  });

  test('sendWifiCredentials resolves false if the speaker closes without ever confirming', () async {
    const ip = '127.0.0.34';
    var responded = false;
    final server = await _startFakeSetupSocket(ip, (ws) {
      ws.listen((data) {
        // Acks only the OPENING message (letting the client proceed to send
        // the survey/profile requests, which then arrive here too but are
        // deliberately ignored - responding to each would race multiple
        // close timers against each other), then goes silent and hangs up -
        // never gets to PerformWirelessSiteSurveyResponse/
        // AddWirelessProfileResponse/NETWORK_WIFI_CONNECTED, simulating a
        // speaker that rejected the profile or dropped off mid-setup.
        if (responded) return;
        responded = true;
        ws.add('<msg>ack SETUP_START</msg>');
        Timer(const Duration(milliseconds: 30), () => ws.close());
      });
    });

    try {
      final result = await BoseWifiSetupService.sendWifiCredentials(
        deviceId: 'ABC123',
        homeSsid: 'HomeNet',
        homePassword: 'secret123',
        isOpenNetwork: false,
        setupIp: ip,
      );
      expect(result.success, false);
    } finally {
      await server.close(force: true);
    }
  });

  test('sendWifiCredentials resolves false when the setup-mode gateway is unreachable', () async {
    final result = await BoseWifiSetupService.sendWifiCredentials(
      deviceId: 'ABC123',
      homeSsid: 'HomeNet',
      homePassword: 'secret123',
      isOpenNetwork: false,
      setupIp: '127.0.0.35',
    );
    expect(result.success, false);
  });
}
