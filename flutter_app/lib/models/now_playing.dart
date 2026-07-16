import 'package:xml/xml.dart';

class NowPlaying {
  final String? source;
  final String? location;
  final String? track;
  final String? stationName;
  final String? playStatus;

  const NowPlaying({this.source, this.location, this.track, this.stationName, this.playStatus});

  bool get isOn => source != null && source!.isNotEmpty && source != 'INVALID_SOURCE';
  bool get isPlaying => playStatus == 'PLAY_STATE';

  String get displayText {
    var text = (source == null || source!.isEmpty) ? 'Standby' : source!;
    if (track != null && track!.isNotEmpty) {
      text += ' — $track';
    } else if (stationName != null && stationName!.isNotEmpty) {
      text += ' — $stationName';
    }
    if (playStatus != null && playStatus!.isNotEmpty) {
      text += ' ($playStatus)';
    }
    return text;
  }

  factory NowPlaying.fromXmlString(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final contentItem = doc.findAllElements('ContentItem').firstOrNull;
    final trackEl = doc.findAllElements('track').firstOrNull;
    final stationNameEl = doc.findAllElements('stationName').firstOrNull;
    final root = doc.rootElement;

    return NowPlaying(
      source: contentItem?.getAttribute('source'),
      location: contentItem?.getAttribute('location'),
      track: trackEl?.innerText,
      stationName: stationNameEl?.innerText,
      playStatus: root.getAttribute('playStatus') ?? _findPlayStatus(doc),
    );
  }

  static String? _findPlayStatus(XmlDocument doc) {
    for (final el in doc.descendants.whereType<XmlElement>()) {
      final attr = el.getAttribute('playStatus');
      if (attr != null) return attr;
    }
    return null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
