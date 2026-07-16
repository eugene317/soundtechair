import 'package:xml/xml.dart';

class VolumeStatus {
  final int actual;

  const VolumeStatus({required this.actual});

  factory VolumeStatus.fromXmlString(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final el = doc.findAllElements('actualvolume').isEmpty
        ? null
        : doc.findAllElements('actualvolume').first;
    return VolumeStatus(actual: int.tryParse(el?.innerText ?? '') ?? 30);
  }
}
