/// Builds playable stream-proxy URLs from raw search-result ids. The search
/// endpoints never return these directly (confirmed in relay-server.ps1) -
/// the client must construct them itself, always from the user-configured
/// Stream Proxy URL setting, never a hardcoded LAN address (that would break
/// the whole point of this app for a speaker in a different house).
class StreamUrlBuilder {
  /// [startSeconds] backs the app's "seek" feature - stream-proxy.ps1 passes
  /// it to ffmpeg as -ss (fast input seek), since this is a live transcode
  /// with no pre-existing indexed file to seek within - a seek is really "a
  /// new stream, starting further into the source," not a jump within an
  /// already-open one.
  static String youtube(String streamProxyUrl, String videoId, {int? startSeconds}) {
    final base = _trimTrailingSlash(streamProxyUrl);
    final suffix = (startSeconds != null && startSeconds > 0) ? '?start=$startSeconds' : '';
    return '$base/stream/$videoId.mp3$suffix';
  }

  static String radio(String streamProxyUrl, String stationId) {
    final base = _trimTrailingSlash(streamProxyUrl);
    return '$base/radio/$stationId.mp3';
  }

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
