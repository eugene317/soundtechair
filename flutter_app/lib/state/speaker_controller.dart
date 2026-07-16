import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/now_playing.dart';
import '../models/preset_slot.dart';
import '../models/search_result.dart';
import '../models/speaker_info.dart';
import '../models/volume_status.dart';
import '../services/discovery.dart';
import '../services/search_api_client.dart';
import '../services/settings_service.dart';
import '../services/soap_client.dart';
import '../services/stream_url_builder.dart';
import '../services/xml_api_client.dart';

const _defaultRadioQuery = 'Top 40';
const _defaultYoutubeQuery = 'Top Hits 2026';

/// The single ChangeNotifier for this app - deliberately not split into
/// Bloc/Riverpod layers, since the state surface is small (one speaker, one
/// now-playing snapshot, two search lists) and a single class keeps every
/// cross-cutting concern (e.g. "don't clobber the volume slider mid-drag")
/// in one obvious place.
class SpeakerController extends ChangeNotifier {
  final _discovery = Discovery();
  final _settingsService = SettingsService();

  DiscoveryStatus discoveryStatus = DiscoveryStatus.idle;
  String discoveryMessage = '';
  SpeakerInfo? speaker;

  NowPlaying? nowPlaying;
  VolumeStatus? volumeStatus;
  Map<String, PresetSlot> presets = {};
  final Set<String> savingPresetNums = {};

  bool isDraggingVolume = false;
  int displayVolume = 30;

  AppSettings settings = AppSettings.empty;

  List<YoutubeResult> youtubeResults = [];
  bool youtubeLoading = false;
  String? youtubeError;

  List<RadioResult> radioResults = [];
  bool radioLoading = false;
  String? radioError;

  String statusMessage = '';
  bool speakerReachable = false;

  Timer? _pollTimer;
  Timer? _volumeDebounceTimer;
  Timer? _retryTimer;

  String get auxToggleTarget => nowPlaying?.source == 'BLUETOOTH' ? 'AUX' : 'BLUETOOTH';

  void setStatusMessage(String message) {
    statusMessage = message;
    notifyListeners();
  }

  Future<void> init() async {
    settings = await _settingsService.loadSettings();
    notifyListeners();

    await _findSpeaker();
    unawaited(searchRadio(_defaultRadioQuery));
    unawaited(searchYoutube(_defaultYoutubeQuery));

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _volumeDebounceTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _findSpeaker() async {
    _retryTimer?.cancel();
    final cached = await _settingsService.loadCachedSpeaker();
    if (cached != null) {
      discoveryStatus = DiscoveryStatus.checkingCached;
      discoveryMessage = 'Checking last known speaker...';
      notifyListeners();
      final confirmed = await _discovery.probeKnownIp(cached.ip);
      if (confirmed != null) {
        await _onSpeakerFound(confirmed);
        return;
      }
    }
    await _scanForSpeaker();
  }

  Future<void> _scanForSpeaker() async {
    discoveryStatus = DiscoveryStatus.scanning;
    discoveryMessage = 'Searching for your speaker...';
    notifyListeners();

    final found = await _discovery.scanSubnet(
      onStatus: (msg) {
        discoveryMessage = msg;
        notifyListeners();
      },
    );

    if (found != null) {
      await _onSpeakerFound(found);
    } else {
      discoveryStatus = DiscoveryStatus.retrying;
      discoveryMessage = 'No speaker found. Retrying in 10s...';
      notifyListeners();
      _retryTimer = Timer(const Duration(seconds: 10), _scanForSpeaker);
    }
  }

  Future<void> _onSpeakerFound(SpeakerInfo info) async {
    speaker = info;
    discoveryStatus = DiscoveryStatus.found;
    await _settingsService.saveSpeaker(info);
    notifyListeners();
    await refreshStatus();
    await _refreshPresets();
  }

  Future<void> rescanSpeaker() async {
    await _settingsService.clearCachedSpeaker();
    speaker = null;
    discoveryStatus = DiscoveryStatus.idle;
    notifyListeners();
    await _scanForSpeaker();
  }

  Future<void> setManualIp(String ip) async {
    discoveryStatus = DiscoveryStatus.checkingCached;
    discoveryMessage = 'Checking $ip...';
    notifyListeners();
    final info = await _discovery.probeKnownIp(ip);
    if (info != null) {
      await _onSpeakerFound(info);
    } else {
      statusMessage = 'Could not reach a SoundTouch speaker at $ip';
      notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    try {
      final np = await XmlApiClient.getNowPlaying(ip);
      final vol = await XmlApiClient.getVolumeStatus(ip);
      nowPlaying = np;
      speakerReachable = true;
      if (!isDraggingVolume) {
        volumeStatus = vol;
        displayVolume = vol.actual;
      }
    } catch (_) {
      speakerReachable = false;
    }
    notifyListeners();
  }

  Future<void> _refreshPresets() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    try {
      presets = await XmlApiClient.getPresets(ip);
      notifyListeners();
    } catch (_) {
      // Leave the previous preset snapshot in place on transient failure.
    }
  }

  bool isPresetPlaying(String num) {
    final loc = presets[num]?.contentItemLocation;
    if (loc == null || loc.isEmpty) return false;
    return loc == nowPlaying?.location;
  }

  Future<void> _withStatus(String message, Future<void> Function() action) async {
    statusMessage = message;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      statusMessage = 'Error: $e';
      notifyListeners();
    }
  }

  Future<void> sendKey(String key) async {
    final ip = speaker?.ip;
    if (ip == null) return;
    await _withStatus('', () async {
      await XmlApiClient.sendKey(ip, key);
      Timer(const Duration(milliseconds: 500), refreshStatus);
    });
  }

  Future<void> stop() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    await _withStatus('Stopping...', () async {
      await SoapClient.stop(ip);
      Timer(const Duration(milliseconds: 500), refreshStatus);
    });
  }

  Future<void> toggleAuxSource() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    final target = auxToggleTarget;
    await _withStatus('Switching to $target...', () async {
      await XmlApiClient.selectSource(ip, target);
      Timer(const Duration(milliseconds: 800), refreshStatus);
    });
  }

  /// Continuous drag feedback: updates the visible number immediately, but
  /// debounces the actual network call 120ms so a fast drag doesn't flood
  /// the speaker with volume-set requests.
  void onVolumeInput(int level) {
    isDraggingVolume = true;
    displayVolume = level;
    notifyListeners();
    _volumeDebounceTimer?.cancel();
    final ip = speaker?.ip;
    if (ip == null) return;
    _volumeDebounceTimer = Timer(const Duration(milliseconds: 120), () {
      XmlApiClient.setVolume(ip, level);
    });
  }

  Future<void> onVolumeChange(int level) async {
    _volumeDebounceTimer?.cancel();
    final ip = speaker?.ip;
    displayVolume = level;
    notifyListeners();
    if (ip != null) {
      await _withStatus('Setting volume to $level...', () async {
        await XmlApiClient.setVolume(ip, level);
        Timer(const Duration(milliseconds: 500), refreshStatus);
      });
    }
    isDraggingVolume = false;
    notifyListeners();
  }

  Future<void> volStep(int delta) async {
    final newVal = (displayVolume + delta).clamp(0, 100);
    await onVolumeChange(newVal);
  }

  Future<void> playPreset(String num) async {
    final ip = speaker?.ip;
    if (ip == null) return;
    final url = presets[num]?.contentItemLocation;
    if (url == null || url.isEmpty) {
      statusMessage = 'Preset $num is empty.';
      notifyListeners();
      return;
    }
    await _withStatus('Playing preset $num...', () async {
      await SoapClient.play(ip, url);
      Timer(const Duration(milliseconds: 1500), refreshStatus);
    });
  }

  Future<void> savePreset(String num) async {
    final ip = speaker?.ip;
    if (ip == null) return;
    savingPresetNums.add(num);
    notifyListeners();
    await _withStatus('Saving current station to preset $num...', () async {
      await XmlApiClient.saveToPreset(ip, num);
      await _refreshPresets();
      Timer(const Duration(milliseconds: 1000), refreshStatus);
    });
    savingPresetNums.remove(num);
    notifyListeners();
  }

  Future<void> playCustomUrl(String url, String label) async {
    final ip = speaker?.ip;
    if (ip == null) return;
    await _withStatus('Loading $label...', () async {
      await SoapClient.play(ip, url);
      Timer(const Duration(milliseconds: 1500), refreshStatus);
    });
  }

  Future<void> searchRadio(String query) async {
    if (query.isEmpty || !settings.isConfigured) return;
    radioLoading = true;
    radioError = null;
    notifyListeners();
    try {
      radioResults = await SearchApiClient.searchRadio(settings.searchServerUrl, query);
    } catch (e) {
      radioError = '$e';
      radioResults = [];
    }
    radioLoading = false;
    notifyListeners();
  }

  Future<void> searchYoutube(String query) async {
    if (query.isEmpty || !settings.isConfigured) return;
    youtubeLoading = true;
    youtubeError = null;
    notifyListeners();
    try {
      youtubeResults = await SearchApiClient.searchYoutube(settings.searchServerUrl, query);
    } catch (e) {
      youtubeError = '$e';
      youtubeResults = [];
    }
    youtubeLoading = false;
    notifyListeners();
  }

  Future<void> playRadioResult(RadioResult r) async {
    final url = StreamUrlBuilder.radio(settings.streamProxyUrl, r.id);
    await playCustomUrl(url, '${r.name} (TuneIn)');
  }

  Future<void> playYoutubeResult(YoutubeResult r) async {
    final url = StreamUrlBuilder.youtube(settings.streamProxyUrl, r.id);
    await playCustomUrl(url, '${r.title} (YouTube)');
  }

  bool isRadioPlaying(RadioResult r) {
    if (!settings.isConfigured) return false;
    return StreamUrlBuilder.radio(settings.streamProxyUrl, r.id) == nowPlaying?.location;
  }

  bool isYoutubePlaying(YoutubeResult r) {
    if (!settings.isConfigured) return false;
    return StreamUrlBuilder.youtube(settings.streamProxyUrl, r.id) == nowPlaying?.location;
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    settings = newSettings;
    await _settingsService.saveSettings(newSettings);
    notifyListeners();
    unawaited(searchRadio(_defaultRadioQuery));
    unawaited(searchYoutube(_defaultYoutubeQuery));
  }
}
