import 'package:xml/xml.dart';

class ZoneMember {
  final String deviceId;
  final String ipAddress;

  const ZoneMember({required this.deviceId, required this.ipAddress});
}

/// A SoundTouch "Zone" (multi-room group) - a DIFFERENT feature from the
/// stereo "group" pairing in group_info.dart (arbitrary N members, all
/// playing the SAME full mix in sync, rather than exactly 2 members each
/// playing one L/R channel of a split stereo signal). Parsed from the
/// /getZone XML response. Null/absent `master` attribute means no active
/// zone. Endpoint paths and this shape are the well-documented SoundTouch
/// WebServices API, matching the same family GroupInfo/getGroup already use
/// - NOT YET confirmed against this project's real hardware the way
/// XmlApiClient._groupPath's own doc comment describes for /getGroup (an
/// earlier guess for that one, /group, 404d on the real device before
/// /getGroup was confirmed to work) - if any of these turn out wrong once
/// tested against a real speaker, expect the same kind of one-path fix.
class ZoneInfo {
  final String masterDeviceId;
  final List<ZoneMember> members; // includes the master itself, per the real API shape

  const ZoneInfo({required this.masterDeviceId, required this.members});

  static ZoneInfo? fromXmlString(String xmlString) {
    try {
      final doc = XmlDocument.parse(xmlString);
      final root = doc.rootElement;
      final master = root.getAttribute('master');
      if (master == null || master.isEmpty) return null;
      final members = <ZoneMember>[];
      for (final el in root.findElements('member')) {
        final ip = el.getAttribute('ipaddress');
        final deviceId = el.innerText.trim();
        if (ip == null || ip.isEmpty || deviceId.isEmpty) continue;
        members.add(ZoneMember(deviceId: deviceId, ipAddress: ip));
      }
      if (members.isEmpty) return null;
      return ZoneInfo(masterDeviceId: master, members: members);
    } catch (_) {
      return null;
    }
  }
}
