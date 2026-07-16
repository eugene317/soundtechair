class AppSettings {
  final String searchServerUrl;
  final String streamProxyUrl;

  const AppSettings({required this.searchServerUrl, required this.streamProxyUrl});

  bool get isConfigured => searchServerUrl.isNotEmpty && streamProxyUrl.isNotEmpty;

  AppSettings copyWith({String? searchServerUrl, String? streamProxyUrl}) => AppSettings(
        searchServerUrl: searchServerUrl ?? this.searchServerUrl,
        streamProxyUrl: streamProxyUrl ?? this.streamProxyUrl,
      );

  static const empty = AppSettings(searchServerUrl: '', streamProxyUrl: '');
}
