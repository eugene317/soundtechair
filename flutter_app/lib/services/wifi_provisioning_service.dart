import 'dart:convert';
import 'package:http/http.dart' as http;

/// WiFi provisioning for a brand-new/factory-reset speaker, based on
/// community-reverse-engineered endpoints (gesellix/Bose-SoundTouch's
/// "AfterTouch" toolkit - hands-on-verified against a real SoundTouch 10,
/// but NOT official Bose documentation). Confidence is medium-high on the
/// request shapes, but there is no documented/verified "did it join"
/// signal - the caller must poll for the speaker's reappearance on the
/// home network separately (see Discovery.scanSubnet).
///
/// Known risk, worth remembering if this fails against a real unit: a
/// secondhand, unverified source claims the setup-mode gateway IP might
/// instead be 192.168.1.1 - hence the fallback list below.
class WifiProvisioningService {
  static const _setupIpCandidates = ['192.0.2.1', '192.168.1.1'];
  static const _timeout = Duration(seconds: 8);

  /// Returns the setup-mode IP that actually responded, so the caller can
  /// report which one worked (useful for debugging against a real unit).
  static Future<String> submitWifiProfile({
    required String ssid,
    required String password,
    bool isOpenNetwork = false,
  }) async {
    final securityType = isOpenNetwork ? 'none' : 'wpa_or_wpa2';
    final escapedSsid = _escapeXml(ssid);
    final escapedPassword = _escapeXml(password);
    final body = '<AddWirelessProfile>\n'
        '  <profile ssid="$escapedSsid" password="$escapedPassword" securityType="$securityType" />\n'
        '</AddWirelessProfile>';

    Object? lastError;
    for (final ip in _setupIpCandidates) {
      try {
        final response = await http
            .post(
              Uri.parse('http://$ip:8090/addWirelessProfile'),
              headers: {'Content-Type': 'text/xml'},
              body: utf8.encode(body),
            )
            .timeout(_timeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return ip;
        }
        lastError = 'HTTP ${response.statusCode} from $ip';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Could not reach the speaker\'s setup mode at any known address. Last error: $lastError');
  }

  static Future<bool> isInSetupMode() async {
    for (final ip in _setupIpCandidates) {
      try {
        final response = await http.get(Uri.parse('http://$ip:8090/info')).timeout(_timeout);
        if (response.statusCode == 200) return true;
      } catch (_) {
        // try next candidate
      }
    }
    return false;
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
