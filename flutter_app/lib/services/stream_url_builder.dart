/// Builds playable stream-proxy URLs from raw search-result ids. The search
/// endpoints never return these directly (confirmed in relay-server.ps1) -
/// the client must construct them itself, always from the user-configured
/// Stream Proxy URL setting, never a hardcoded LAN address (that would break
/// the whole point of this app for a speaker in a different house).
class StreamUrlBuilder {
  static String youtube(String streamProxyUrl, String videoId) {
    final base = _trimTrailingSlash(streamProxyUrl);
    return '$base/stream/$videoId.mp3';
  }

  static String radio(String streamProxyUrl, String stationId) {
    final base = _trimTrailingSlash(streamProxyUrl);
    return '$base/radio/$stationId.mp3';
  }

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
