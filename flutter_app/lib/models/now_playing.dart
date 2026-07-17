import 'package:xml/xml.dart';

class NowPlaying {
  final String? source;
  final String? location;
  final String? track;
  final String? stationName;
  final String? playStatus;

  /// The <time total="..."> element's inner text - the ELAPSED seconds, not
  /// the "total" attribute (which is confirmed unreliable/often 0 for
  /// on-demand streams). Elapsed time actually advancing between polls is a
  /// much more trustworthy "still genuinely playing" signal than playStatus
  /// string matching alone, since the exact set of transient non-PLAY_STATE
  /// values the speaker reports during startup/buffering isn't fully known.
  final int? elapsedSeconds;

  const NowPlaying({
    this.source,
    this.location,
    this.track,
    this.stationName,
    this.playStatus,
    this.elapsedSeconds,
  });

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
    final timeEl = doc.findAllElements('time').firstOrNull;
    final root = doc.rootElement;

    return NowPlaying(
      source: contentItem?.getAttribute('source'),
      location: contentItem?.getAttribute('location'),
      track: trackEl?.innerText,
      stationName: stationNameEl?.innerText,
      playStatus: root.getAttribute('playStatus') ?? _findPlayStatus(doc),
      elapsedSeconds: int.tryParse(timeEl?.innerText ?? ''),
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
