import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// Direct UPnP AVTransport SOAP control, ported 1:1 from SoundTouch-Common.ps1's
/// Invoke-SoapAction / Start-StationPlayback / Stop-StationPlayback. Unlike the
/// PowerShell original (which never reads the response body), failures here
/// parse the UPnP SOAP Fault body for the real errorCode/errorDescription -
/// a bare HTTP 500 alone doesn't say whether the speaker rejected the URI's
/// scheme (e.g. https), MIME type, or something else entirely.
class SoapClient {
  static const _timeout = Duration(seconds: 8);

  static Future<void> _invoke(String speakerIp, String action, String body) async {
    final uri = Uri.parse('http://$speakerIp:8091/AVTransport/Control');
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
          },
          body: utf8.encode(body),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('SOAP $action failed: HTTP ${response.statusCode}${_describeFault(response.body)}');
    }
  }

  /// Extracts errorCode/errorDescription from a UPnP SOAP Fault body, if
  /// present. UPnP signals errors via HTTP 500 + a SOAP Fault envelope, not
  /// via HTTP status codes alone - so the fault body is the only place the
  /// real reason (e.g. "Illegal MIME-Type", "Invalid Args") shows up.
  static String _describeFault(String body) {
    try {
      final doc = XmlDocument.parse(body);
      final codeEl = doc.findAllElements('errorCode').firstOrNull;
      final descEl = doc.findAllElements('errorDescription').firstOrNull;
      if (codeEl != null || descEl != null) {
        return ' (UPnP error ${codeEl?.innerText ?? '?'}: ${descEl?.innerText ?? 'unknown'})';
      }
    } catch (_) {
      // Body wasn't parseable XML - fall through to the raw dump below.
    }
    if (body.isNotEmpty) {
      final snippet = body.length > 300 ? '${body.substring(0, 300)}...' : body;
      return ' - body: $snippet';
    }
    return '';
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static Future<void> play(String speakerIp, String streamUrl) async {
    final escapedUrl = _escapeXml(streamUrl);
    final setUriBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>$escapedUrl</CurrentURI>
      <CurrentURIMetaData></CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''';
    await _invoke(speakerIp, 'SetAVTransportURI', setUriBody);

    const playBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';
    await _invoke(speakerIp, 'Play', playBody);
  }

  static Future<void> stop(String speakerIp) async {
    const stopBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>''';
    await _invoke(speakerIp, 'Stop', stopBody);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
