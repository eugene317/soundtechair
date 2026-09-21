import 'package:xml/xml.dart';

enum StereoRole { left, right }

class GroupRole {
  final String deviceId;
  final StereoRole role;
  final String ipAddress;

  const GroupRole({required this.deviceId, required this.role, required this.ipAddress});
}

/// A SoundTouch "stereo pair" grouping - a different feature from the plain
/// multi-room "zone" API (no L/R concept there). Parsed from the /group
/// (unconfirmed against real hardware - see XmlApiClient._groupPath) XML
/// response. Null/absent `<roles>` means no active pairing.
class GroupInfo {
  final String id;
  final String name;
  final String masterDeviceId;
  final List<GroupRole> roles;

  const GroupInfo({required this.id, required this.name, required this.masterDeviceId, required this.roles});

  /// Returns null for an empty `<group/>` (no active pairing) or any
  /// malformed response, rather than throwing - callers treat "not paired"
  /// and "couldn't tell" the same way.
  static GroupInfo? fromXmlString(String xmlString) {
    try {
      final doc = XmlDocument.parse(xmlString);
      final root = doc.rootElement;
      final rolesEl = root.findElements('roles');
      if (rolesEl.isEmpty) return null;
      final roles = <GroupRole>[];
      for (final roleEl in rolesEl.first.findElements('groupRole')) {
        final deviceId = roleEl.findElements('deviceId').isEmpty ? null : roleEl.findElements('deviceId').first.innerText;
        final roleText = roleEl.findElements('role').isEmpty ? null : roleEl.findElements('role').first.innerText;
        final ip = roleEl.findElements('ipAddress').isEmpty ? null : roleEl.findElements('ipAddress').first.innerText;
        if (deviceId == null || roleText == null || ip == null) continue;
        final role = roleText.toUpperCase() == 'LEFT' ? StereoRole.left : StereoRole.right;
        roles.add(GroupRole(deviceId: deviceId, role: role, ipAddress: ip));
      }
      if (roles.length != 2) return null;
      final masterEl = root.findElements('masterDeviceId');
      final nameEl = root.findElements('name');
      return GroupInfo(
        id: root.getAttribute('id') ?? '',
        name: nameEl.isEmpty ? '' : nameEl.first.innerText,
        masterDeviceId: masterEl.isEmpty ? '' : masterEl.first.innerText,
        roles: roles,
      );
    } catch (_) {
      return null;
    }
  }
}
