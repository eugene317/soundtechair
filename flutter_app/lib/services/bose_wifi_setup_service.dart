import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WiFi provisioning over the SAME WebSocket setup protocol the official
/// Bose SoundTouch app uses (confirmed by decompiling its APK, 2026-07-22 -
/// see com.bosesoundtouch.controller.setup.WifiSetupManager.setupViaWebSocket),
/// rather than this app's old one-shot HTTP POST to /addWirelessProfile.
///
/// The key advantage over the old approach: this protocol gets a real,
/// speaker-confirmed "NETWORK_WIFI_CONNECTED" push message once the speaker
/// has actually joined the home network - not a guess based on the setup AP
/// going quiet. Requires the phone to already be connected (manually, via
/// WiFi Settings - see WifiSetupScreen) to the speaker's temporary setup AP,
/// since every request here goes to the setup-mode gateway address.
typedef WifiSetupResult = ({bool success, String? detail});

class BoseWifiSetupService {
  static const _setupIp = '192.0.2.1';
  static const _timeout = Duration(seconds: 15);

  /// GET /info and pull out the deviceID attribute - every setup message
  /// below must carry this in its header for the speaker to accept it.
  /// [setupIp] defaults to the real setup-mode gateway address; tests
  /// override it to point at an injectable loopback fixture instead (the
  /// real address, 192.0.2.1, is reserved TEST-NET-1 and not bindable on a
  /// dev machine - same reasoning as the old WifiProvisioningService's
  /// setupIpCandidates parameter it replaces).
  static Future<String?> getDeviceId({String setupIp = _setupIp}) async {
    try {
      final response = await http.get(Uri.parse('http://$setupIp:8090/info')).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final match = RegExp('deviceID="([^"]+)"').firstMatch(response.body);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  static String _buildMsg(String deviceId, String url, String method, int requestId, String body) {
    return '<msg><header deviceID="$deviceId" url="$url" method="$method">'
        '<request requestID="$requestId"></request></header>$body</msg>';
  }

  /// Runs the full setup conversation over ws://192.0.2.1:8080/ (the same
  /// "gabbo" control socket preset-listener.ps1 already listens on for
  /// notifications - this is the same speaker-side service, just driving it
  /// instead of just listening) and resolves true only once the speaker
  /// itself reports NETWORK_WIFI_CONNECTED. [onStatus] gets a short
  /// human-readable line for each step, for a live-progress UI.
  ///
  /// On failure, [WifiSetupResult.detail] names the specific stage the
  /// handshake got stuck at (WS never connected / never got a reply / got
  /// replies but the connection died / sat waiting past the timeout) -
  /// added 2026-07-28 after a field report of this failing with only "the
  /// speaker didn't confirm - check your password", which is equally true
  /// (and equally unhelpful) whether the WebSocket never connected, the
  /// speaker never replied to anything, or it replied right up until the
  /// last step then the connection silently died - three very different
  /// problems that generic message couldn't tell apart.
  static Future<WifiSetupResult> sendWifiCredentials({
    required String deviceId,
    required String homeSsid,
    required String homePassword,
    required bool isOpenNetwork,
    void Function(String status)? onStatus,
    String setupIp = _setupIp,
  }) async {
    final securityType = isOpenNetwork ? 'none' : 'wpa_or_wpa2';
    final completer = Completer<WifiSetupResult>();
    var requestId = 21;
    var surveyHandled = false;
    // Tracks the furthest point reached in the handshake, so a failure that
    // happens anywhere after connecting can still report specifically what
    // it was waiting on when it died.
    var stage = 'connecting to the speaker';
    WebSocketChannel? channel;
    Timer? timeoutTimer;

    void finish(bool success, [String? detail]) {
      timeoutTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete((success: success, detail: success ? null : detail));
      }
      channel?.sink.close();
    }

    try {
      channel = IOWebSocketChannel.connect(
        Uri.parse('ws://$setupIp:8080/'),
        protocols: ['gabbo'],
        connectTimeout: _timeout,
      );
      // IOWebSocketChannel.connect() returns synchronously and never throws
      // for a connection failure itself - the actual TCP/handshake attempt
      // happens in the background and its failure only surfaces via
      // `ready` (or, later, the stream's error event - but by then it can
      // race an unhandled-async-error report if nothing has awaited
      // anything yet). Awaiting `ready` here is the documented-safe way to
      // catch a refused/unreachable connection before proceeding.
      await channel.ready;
    } catch (e) {
      return (success: false, detail: 'Could not open a connection to the speaker at all ($e). '
          'Your phone may no longer be on the speaker\'s setup WiFi.');
    }

    // The speaker's own setup flow can legitimately take longer than a
    // single HTTP call (a real WiFi join, not just an HTTP round trip) -
    // matches this app's existing patience elsewhere for the same reason,
    // but still needs a ceiling so a silently-stuck speaker doesn't hang
    // this screen forever.
    timeoutTimer = Timer(
      const Duration(seconds: 60),
      () => finish(false, 'The speaker never confirmed it joined the network - still waiting on: $stage.'),
    );

    channel.stream.listen(
      (event) {
        final text = event is String ? event : utf8.decode(event as List<int>);
        if (text.contains('SETUP_START')) {
          stage = 'the WiFi site survey response';
          onStatus?.call('Preparing speaker for setup...');
          channel!.sink.add(_buildMsg(deviceId, 'language', 'POST', requestId++, '<body><sysLanguage>3</sysLanguage></body>'));
          channel.sink.add(
            _buildMsg(deviceId, 'performWirelessSiteSurvey', 'POST', requestId++, '<body><PerformWirelessSiteSurvey timeout="8" /></body>'),
          );
          channel.sink.add(
            _buildMsg(deviceId, 'setup', 'POST', requestId++, '<body><setupState state="SETUP_IDENTIFY_DEVICE_ENTER" timeout="300000"/></body>'),
          );
        } else if (text.contains('PerformWirelessSiteSurveyResponse') && !surveyHandled) {
          surveyHandled = true;
          stage = 'the speaker accepting the WiFi credentials';
          onStatus?.call('Sending WiFi credentials to speaker...');
          channel!.sink.add(_buildMsg(deviceId, 'setup', 'POST', requestId++, '<body><setupState state="SETUP_IDENTIFY_DEVICE_LEAVE" /></body>'));
          final escapedSsid = _escapeXml(homeSsid);
          final escapedPassword = _escapeXml(homePassword);
          channel.sink.add(
            _buildMsg(deviceId, 'addWirelessProfile', 'POST', requestId++,
                '<body><AddWirelessProfile timeout="90"><profile ssid="$escapedSsid" password="$escapedPassword" securityType="$securityType" ></profile></AddWirelessProfile></body>'),
          );
        } else if (text.contains('AddWirelessProfileResponse')) {
          stage = 'the speaker confirming it joined the network';
          onStatus?.call('Speaker is joining your WiFi...');
          channel!.sink.add(_buildMsg(deviceId, 'setup', 'POST', requestId++, '<body><setupState state="SETUP_WIFI_LEAVE" /></body>'));
        } else if (text.contains('NETWORK_WIFI_CONNECTED')) {
          onStatus?.call('Speaker connected to your WiFi!');
          finish(true);
        }
      },
      onError: (e) => finish(false, 'The connection to the speaker failed while waiting on: $stage ($e).'),
      onDone: () => finish(false, 'The connection to the speaker closed unexpectedly while waiting on: $stage.'),
    );

    channel.sink.add(_buildMsg(deviceId, 'setup', 'POST', requestId++, '<body><setupState state="SETUP_START" /></body>'));

    return completer.future;
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
