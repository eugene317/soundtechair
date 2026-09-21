import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:network_info_plus/network_info_plus.dart';

import '../models/speaker_info.dart';
import '../utils/subnet_math.dart';
import 'xml_api_client.dart';

enum DiscoveryStatus { idle, checkingCached, scanning, found, retrying }

/// True for 192.0.2.0/24 (RFC 5737 TEST-NET-1) - the fixed gateway/subnet a
/// SoundTouch speaker's OWN temporary setup-mode AP uses (see
/// BoseWifiSetupService, which talks to it at exactly 192.0.2.1), never a
/// real home router's subnet. A standalone top-level function (not inlined
/// into Discovery.scanSubnet) so it's directly unit-testable without needing
/// to mock network_info_plus.
bool isSetupModeSubnet(String ip) => ip.startsWith('192.0.2.');

/// Dart port of Find-SoundTouchSpeaker (SoundTouch-Common.ps1). Android has no
/// equivalent of Get-NetIPConfiguration's exact prefix length, so this defaults
/// to /24 when network_info_plus can't report a subnet mask - an accepted
/// approximation that covers the overwhelming majority of home routers.
class Discovery {
  static const _tcpProbeTimeout = Duration(milliseconds: 400);
  static const _confirmTimeout = Duration(seconds: 3);
  static const _batchSize = 128;

  final _networkInfo = NetworkInfo();

  /// Fast path: re-check a single previously-known IP. Used on app resume so
  /// a full rescan isn't needed unless the speaker's address actually changed.
  Future<SpeakerInfo?> probeKnownIp(String ip) async {
    final reachable = await _tcpProbe(ip);
    if (!reachable) return null;
    return _confirm(ip);
  }

  Future<int> _prefixLength() async {
    String? mask;
    try {
      mask = await _networkInfo.getWifiSubmask();
    } catch (_) {
      return 24;
    }
    if (mask == null) return 24;
    try {
      final maskInt = SubnetMath.ipStringToInt(mask);
      var prefix = 0;
      var remaining = maskInt;
      for (var i = 0; i < 32; i++) {
        if (remaining & 0x80000000 != 0) prefix++;
        remaining <<= 1;
      }
      return prefix == 0 ? 24 : prefix;
    } catch (_) {
      return 24;
    }
  }

  /// Full subnet scan - finds every SoundTouch speaker on the LAN, not just
  /// the first one. Reports progress via [onStatus] as it goes.
  Future<List<SpeakerInfo>> scanSubnet({void Function(String message)? onStatus}) async {
    String? localIp;
    try {
      localIp = await _networkInfo.getWifiIP();
    } catch (_) {
      localIp = null;
    }
    if (localIp == null) {
      onStatus?.call('No WiFi connection detected.');
      return [];
    }
    // See isSetupModeSubnet's own doc comment for what this guards against -
    // confirmed live (2026-07-25): right after sending WiFi credentials, the
    // phone can still be connected to the speaker's temp AP for a few
    // seconds while it switches back to the home network, and the speaker's
    // setup-mode HTTP server is still answering /info on it during that
    // window - scanning it "successfully" finds the speaker at 192.0.2.1, a
    // session the app then can't actually reach once that AP disappears
    // (the exact "cannot connect" bug this guard exists for). Bailing out
    // here instead of scanning it means the caller's own retry loop (see
    // SpeakerController._scanForSpeakers) tries again shortly after, by
    // which point the phone has normally finished switching back.
    if (isSetupModeSubnet(localIp)) {
      onStatus?.call('Still on the speaker\'s setup network - waiting for your phone to switch back to your home WiFi...');
      return [];
    }
    final prefix = await _prefixLength();
    final hosts = SubnetMath.hostAddresses(localIp, prefix);

    onStatus?.call('Scanning ${hosts.length} addresses on your network...');

    final candidates = <String>[];
    for (var i = 0; i < hosts.length; i += _batchSize) {
      final batch = hosts.sublist(i, i + _batchSize > hosts.length ? hosts.length : i + _batchSize);
      final results = await Future.wait(batch.map((ip) async {
        final reachable = await _tcpProbe(ip);
        return reachable ? ip : null;
      }));
      candidates.addAll(results.whereType<String>());
    }

    if (candidates.isEmpty) return [];

    onStatus?.call('Confirming ${candidates.length} candidate(s)...');
    // Confirm in the same-size batches as the TCP-probe phase above, rather
    // than one at a time - on web every subnet address becomes a "candidate"
    // (see _tcpProbe's kIsWeb branch), so a sequential confirm loop with a
    // 3s timeout each could take minutes; batching keeps it fast while still
    // checking every candidate instead of stopping at the first match.
    final found = <SpeakerInfo>[];
    for (var i = 0; i < candidates.length; i += _batchSize) {
      final batch = candidates.sublist(i, i + _batchSize > candidates.length ? candidates.length : i + _batchSize);
      final results = await Future.wait(batch.map(_confirm));
      found.addAll(results.whereType<SpeakerInfo>());
    }
    return found;
  }

  Future<bool> _tcpProbe(String ip) async {
    // dart:io sockets don't exist on web; defer to the HTTP-based _confirm()
    // step instead of unconditionally reporting every host as unreachable.
    if (kIsWeb) return true;
    try {
      final socket = await Socket.connect(ip, 8090, timeout: _tcpProbeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<SpeakerInfo?> _confirm(String ip) async {
    try {
      final info = await XmlApiClient.getInfo(ip).timeout(_confirmTimeout);
      if (info.deviceId.isEmpty) return null;
      return info;
    } catch (_) {
      return null;
    }
  }
}
