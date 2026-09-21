import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

import 'soap_client.dart';

/// Ported 1:1 from this project's preset-listener.ps1 (a PC-side PowerShell
/// script), running inside the app instead - so a physical preset-button
/// press on the paired speaker gets the same Stop-then-SetAVTransportURI-
/// then-Play retry kick that a real SoundTouch's own native preset recall
/// has been directly observed (2026-07-2x, manual SOAP testing against real
/// hardware) to sometimes accept with HTTP 200 and then never actually
/// complete. Running this in the app - not just the PC script - means the
/// phone itself, being on the same LAN as its own paired speaker, can catch
/// and retry a physical press even when the PC-side script is down/crashed/
/// not running at all (e.g. a different household with no PC backend of
/// its own, only this app).
///
/// Subscribes to the speaker's own notification WebSocket (port 8080,
/// subprotocol "gabbo" - same endpoint the real Bose app itself uses) rather
/// than polling, so a press is caught the instant it happens.
class PresetButtonRelayService {
  PresetButtonRelayService(this.speakerIp, {WebSocketChannel Function(Uri uri)? channelFactory})
      : _channelFactory = channelFactory ?? _defaultChannelFactory;

  final String speakerIp;
  final WebSocketChannel Function(Uri uri) _channelFactory;

  static WebSocketChannel _defaultChannelFactory(Uri uri) => WebSocketChannel.connect(uri, protocols: ['gabbo']);

  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _stopped = true;

  // Dedup guard: the SAME (presetId, location) pair arriving again within
  // this window is skipped rather than re-triggering a redundant replay -
  // the speaker's own notification socket has been observed (see
  // preset-listener.ps1) emitting more than one nowSelectionUpdated for a
  // single physical press.
  static const _dedupWindow = Duration(seconds: 3);
  String? _lastKey;
  DateTime? _lastAt;

  bool get isRunning => !_stopped;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _connect() {
    if (_stopped) return;
    try {
      final channel = _channelFactory(Uri.parse('ws://$speakerIp:8080/'));
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  // Same fixed 5s retry as preset-listener.ps1's own reconnect loop - no
  // backoff, since a speaker that's merely rebooting or briefly off-network
  // is expected to come back within a few cycles of this.
  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _connect);
  }

  void _handleMessage(dynamic message) {
    final text = message is String ? message : utf8.decode(message as List<int>);
    if (!text.contains('nowSelectionUpdated')) return;
    try {
      final doc = XmlDocument.parse(text);
      final presetEl = doc.findAllElements('preset').firstOrNull;
      if (presetEl == null) return;
      final presetId = presetEl.getAttribute('id') ?? '';
      final location = presetEl.findAllElements('ContentItem').firstOrNull?.getAttribute('location');
      if (location == null || location.trim().isEmpty) return;

      final key = '$presetId|$location';
      final now = DateTime.now();
      if (key == _lastKey && _lastAt != null && now.difference(_lastAt!) < _dedupWindow) {
        return;
      }
      _lastKey = key;
      _lastAt = now;

      unawaited(_replay(location));
    } catch (_) {
      // Unexpected/malformed notification payload - ignore this one, the
      // next message (or the next press) may still parse fine.
    }
  }

  Future<void> _replay(String location) async {
    try {
      await SoapClient.stop(speakerIp);
    } catch (_) {
      // Best-effort, same as preset-listener.ps1's own Stop-first call -
      // proceed to SetAVTransportURI/Play regardless.
    }
    try {
      await SoapClient.play(speakerIp, location);
    } catch (_) {
      // Nothing else to do locally - this retry-kick just doesn't land this
      // time. The next physical press (or the PC-side listener, if one is
      // also running against this same speaker) still gets its own chance.
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
