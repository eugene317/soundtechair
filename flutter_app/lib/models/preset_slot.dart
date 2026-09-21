import 'package:xml/xml.dart';

class PresetSlot {
  final String id;
  final String? contentItemLocation;

  const PresetSlot({required this.id, this.contentItemLocation});

  // .trim() here too, as defense in depth - listFromXmlString below already
  // normalizes a whitespace-only device-reported location to null, but this
  // getter shouldn't silently rely on every construction path remembering
  // that (e.g. a future caller building a PresetSlot directly, or a test).
  bool get isEmpty => contentItemLocation == null || contentItemLocation!.trim().isEmpty;

  static Map<String, PresetSlot> listFromXmlString(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final result = <String, PresetSlot>{};
    for (final presetEl in doc.findAllElements('preset')) {
      final id = presetEl.getAttribute('id');
      if (id == null) continue;
      final contentItem = presetEl.findElements('ContentItem').isEmpty
          ? null
          : presetEl.findElements('ContentItem').first;
      final rawLocation = contentItem?.getAttribute('location');
      // A `location` attribute that's present but pure whitespace is
      // functionally "no URI" from the device's own perspective - normalize
      // it to null right here, so every consumer (playPreset's null/isEmpty
      // guard, isPresetPlaying, isEmpty above) is protected by ONE check
      // instead of each call site having to remember to .trim() separately.
      // This is the field-incident guard: a preset slot that's technically
      // "occupied" but whitespace-only used to slip past a plain
      // `url.isEmpty` check and reach SoapClient.play with a blank
      // CurrentURI, which a real SoundTouch 10 rejects as UPnP error 402
      // "Can't play. No URI supplied." (confirmed via curl, 2026-07-2x).
      final location = (rawLocation == null || rawLocation.trim().isEmpty) ? null : rawLocation;
      result[id] = PresetSlot(id: id, contentItemLocation: location);
    }
    return result;
  }
}
