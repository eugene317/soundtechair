import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../models/speaker_info.dart';
import '../utils/subnet_math.dart';
import 'xml_api_client.dart';

enum DiscoveryStatus { idle, checkingCached, scanning, found, retrying }

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
    final mask = await _networkInfo.getWifiSubmask();
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

  /// Full subnet scan. Reports progress via [onStatus] as it goes.
  Future<SpeakerInfo?> scanSubnet({void Function(String message)? onStatus}) async {
    final localIp = await _networkInfo.getWifiIP();
    if (localIp == null) {
      onStatus?.call('No WiFi connection detected.');
      return null;
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

    if (candidates.isEmpty) return null;

    onStatus?.call('Confirming ${candidates.length} candidate(s)...');
    for (final ip in candidates) {
      final info = await _confirm(ip);
      if (info != null) return info;
    }
    return null;
  }

  Future<bool> _tcpProbe(String ip) async {
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
