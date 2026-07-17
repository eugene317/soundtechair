import 'package:xml/xml.dart';

class NowPlaying {
  final String? source;
  final String? location;
  final String? track;
  final String? stationName;
  final String? playStatus;

  /// The <time total="..."> element's inner text - elapsed seconds into the
  /// current track. Reliable and always present once playing.
  final int? elapsedSeconds;

  /// The <time total="..."> attribute itself - the track's total duration in
  /// seconds, as reported by the speaker. Only meaningful once we actually
  /// tell the speaker the duration via DIDL-Lite metadata on play (see
  /// SoapClient.play) - 0/null otherwise (e.g. radio, or a source we didn't
  /// send duration metadata for), meaning "unknown," not "zero-length."
  final int? totalSeconds;

  const NowPlaying({
    this.source,
    this.location,
    this.track,
    this.stationName,
    this.playStatus,
    this.elapsedSeconds,
    this.totalSeconds,
  });

  bool get isOn => source != null && source!.isNotEmpty && source != 'INVALID_SOURCE';
  bool get isPlaying => playStatus == 'PLAY_STATE';

  /// True only when the speaker actually knows the track's real duration
  /// (we sent it via DIDL-Lite metadata) - false for radio/unknown-duration
  /// sources, where totalSeconds is 0/absent.
  bool get hasKnownDuration => totalSeconds != null && totalSeconds! > 0;

  static String _formatSeconds(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  /// "2:59 / 3:00" once duration is known, else just "2:59" (elapsed only).
  String? get progressText {
    if (elapsedSeconds == null) return null;
    if (!hasKnownDuration) return _formatSeconds(elapsedSeconds!);
    return '${_formatSeconds(elapsedSeconds!)} / ${_formatSeconds(totalSeconds!)}';
  }

  /// 0.0-1.0 once duration is known, else null (nothing to show a determinate
  /// progress bar against).
  double? get progressFraction {
    if (!hasKnownDuration || elapsedSeconds == null) return null;
    return (elapsedSeconds! / totalSeconds!).clamp(0.0, 1.0);
  }

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
      totalSeconds: int.tryParse(timeEl?.getAttribute('total') ?? ''),
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
