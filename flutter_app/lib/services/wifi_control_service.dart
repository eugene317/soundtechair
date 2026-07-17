import 'package:flutter/services.dart';

/// Thin custom platform-channel wrapper around Android's own
/// WifiManager.disconnect() - used as a best-effort attempt to let Android
/// auto-rejoin a previously-saved network (e.g. the user's home WiFi) once
/// the app no longer needs the speaker's temporary setup-mode AP.
///
/// Deliberately NOT using a pub.dev plugin for this: wifi_iot (the obvious
/// choice) ships an abandoned Android Gradle config that still references
/// the long-shut-down jcenter() repository and lacks a proper Android
/// Gradle Plugin application - it hard-fails the build on this project's
/// (current, modern) Android Gradle Plugin version. A ~15-line native
/// MethodChannel avoids that risk entirely.
class WifiControlService {
  static const _channel = MethodChannel('com.airstaffs.soundtouch_control/wifi');

  /// Returns true if the underlying WifiManager.disconnect() call itself
  /// reported success - this does NOT guarantee Android actually rejoined
  /// another network afterward, just that this step ran without error.
  static Future<bool> disconnect() async {
    try {
      final result = await _channel.invokeMethod<bool>('disconnect');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
