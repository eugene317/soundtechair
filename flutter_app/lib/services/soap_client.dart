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

  /// Empty string when neither title nor duration is given, matching the
  /// original always-empty CurrentURIMetaData exactly - only builds real
  /// DIDL-Lite when a caller actually has something to offer.
  static String _buildDidlLiteMetadata({required String streamUrl, String? title, Duration? duration}) {
    if (title == null && duration == null) return '';
    final escapedTitle = _escapeXml(title ?? 'Unknown');
    final escapedUrl = _escapeXml(streamUrl);
    final durationAttr = duration != null ? ' duration="${_formatDuration(duration)}"' : '';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>$escapedTitle</dc:title>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '<res protocolInfo="http-get:*:audio/mpeg:*"$durationAttr>$escapedUrl</res>'
        '</item>'
        '</DIDL-Lite>';
  }

  /// UPnP's expected res-duration format: "H:MM:SS.mmm".
  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.000';
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// [title]/[duration] are optional - when omitted, CurrentURIMetaData stays
  /// completely empty (the original, proven-working behavior for radio,
  /// presets, and custom URLs). When provided, builds real DIDL-Lite metadata
  /// so the speaker actually knows the track's duration (by default it
  /// doesn't - the speaker reports total=0 for anything played this way
  /// unless we tell it otherwise), which is what lets now_playing report a
  /// real elapsed/total instead of just an ever-climbing elapsed counter.
  static Future<void> play(String speakerIp, String streamUrl, {String? title, Duration? duration}) async {
    final escapedUrl = _escapeXml(streamUrl);
    final metadata = _buildDidlLiteMetadata(streamUrl: streamUrl, title: title, duration: duration);
    final escapedMetadata = _escapeXml(metadata);
    final setUriBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>$escapedUrl</CurrentURI>
      <CurrentURIMetaData>$escapedMetadata</CurrentURIMetaData>
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
