import 'package:xml/xml.dart';

class PresetSlot {
  final String id;
  final String? contentItemLocation;

  const PresetSlot({required this.id, this.contentItemLocation});

  bool get isEmpty => contentItemLocation == null || contentItemLocation!.isEmpty;

  static Map<String, PresetSlot> listFromXmlString(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final result = <String, PresetSlot>{};
    for (final presetEl in doc.findAllElements('preset')) {
      final id = presetEl.getAttribute('id');
      if (id == null) continue;
      final contentItem = presetEl.findElements('ContentItem').isEmpty
          ? null
          : presetEl.findElements('ContentItem').first;
      result[id] = PresetSlot(id: id, contentItemLocation: contentItem?.getAttribute('location'));
    }
    return result;
  }
}
