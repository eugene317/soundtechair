import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/now_playing.dart';
import '../models/playlist.dart';
import '../models/preset_slot.dart';
import '../models/search_result.dart';
import '../models/speaker_info.dart';
import '../models/volume_status.dart';
import '../services/discovery.dart';
import '../services/playlist_service.dart';
import '../services/search_api_client.dart';
import '../services/settings_service.dart';
import '../services/soap_client.dart';
import '../services/stream_url_builder.dart';
import '../services/xml_api_client.dart';

const _defaultRadioQuery = 'Top 40';
const _defaultYoutubeQuery = 'Top Hits 2026';

/// Sequential = playlist's own list order (always re-derived live against
/// [Playlist.tracks], so reordering while it's the active mode takes effect
/// immediately). Shuffle needs its own frozen random order - see
/// SpeakerController._shuffleQueue.
enum PlaylistOrder { sequential, shuffle }

enum PlaylistRepeat { once, loop }

/// The single ChangeNotifier for this app - deliberately not split into
/// Bloc/Riverpod layers, since the state surface is small (one speaker, one
/// now-playing snapshot, two search lists) and a single class keeps every
/// cross-cutting concern (e.g. "don't clobber the volume slider mid-drag")
/// in one obvious place.
class SpeakerController extends ChangeNotifier {
  final _discovery = Discovery();
  final _settingsService = SettingsService();
  final _playlistService = PlaylistService();

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

  // --- Playlist library ---
  List<Playlist> playlists = [];

  // --- Playlist playback session (none of this is persisted - see
  // _stopPlaylistMode's doc comment for why re-adopting stale state on
  // relaunch would do more harm than good) ---
  Playlist? activePlaylist;
  String? _activeTrackId;
  PlaylistOrder playlistOrder = PlaylistOrder.sequential;
  PlaylistRepeat playlistRepeat = PlaylistRepeat.once;
  bool playlistPaused = false;

  /// Frozen random play order (track ids), only used in shuffle mode -
  /// sequential mode instead re-derives "next"/"previous" live against
  /// [activePlaylist]'s own track order, so reordering takes effect
  /// immediately without needing a queue rebuild.
  List<String>? _shuffleQueue;
  int? _shuffleQueuePos;

  String? _lastCommandedLocation;
  bool _confirmedStarted = false;
  int _terminalStreak = 0;
  int _ticksSinceCommand = 0;
  int? _lastElapsedSeconds;

  /// Optimistic bridge flag for the plain transport-row Pause/Play buttons
  /// (outside playlist mode - see playlistPaused for that case). Set/cleared
  /// SYNCHRONOUSLY the instant the button is tapped, before the awaited
  /// XmlApiClient.sendKey round trip even starts, so the display ticker
  /// freezes at the moment of the tap rather than only once nowPlaying's
  /// stale PLAY_STATE finally gets overwritten by the next poll (which was
  /// otherwise a window of over-ticking followed by a backward snap - the
  /// same sawtooth this whole ticker-gating scheme exists to avoid). Only
  /// needs to bridge until the next real poll lands - refreshStatus() clears
  /// it unconditionally as soon as fresh data arrives, since nowPlaying?.isPlaying
  /// alone is authoritative from that point on.
  bool _manuallyPaused = false;

  /// A once-per-second, UI-only estimate of elapsed playback time,
  /// interpolated between the real 5-second now_playing polls so the
  /// on-screen timer/progress bar ticks smoothly instead of visibly jumping
  /// by ~5 every poll. Resynced to the real polled value on every
  /// refreshStatus() tick, so drift never accumulates for more than one poll
  /// interval. The actual auto-advance logic keeps using the real polled
  /// NowPlaying.elapsedSeconds, never this - this field is display-only.
  int? _displayElapsedSeconds;

  /// True once a poll has actually observed PLAY_STATE for the current
  /// track - false during the initial buffering/loading window right after
  /// a track is commanded. The speaker itself appears to report a rising
  /// elapsed count WHILE STILL BUFFERING (observed: counts up during load,
  /// then resets back down once real audio playback actually begins) - so
  /// showing/ticking the display before this is confirmed produces a
  /// confusing "counts up then jumps back to 1" readout that isn't wrong
  /// data, just the wrong phase to be showing a track-position clock for.
  bool _displayConfirmedPlaying = false;

  // --- Seek support (YouTube only - radio/custom URLs have no known
  // duration/seekable position). A "seek" restarts the stream-proxy request
  // with a new ?start= offset (there's no pre-existing indexed file to seek
  // within - this is a live transcode) - so these fields let the display
  // show the TRUE position within the original video (offset + whatever the
  // restarted, trimmed stream itself reports), not the trimmed stream's own
  // 0-based view of itself. ---
  String? _seekableVideoId;
  int? _seekableFullDurationSeconds;
  int _seekOffsetSeconds = 0;

  void _trackSeekableYoutube(String videoId, int? fullDurationSeconds) {
    _seekableVideoId = videoId;
    _seekableFullDurationSeconds = fullDurationSeconds;
    _seekOffsetSeconds = 0;
  }

  void _clearSeekable() {
    _seekableVideoId = null;
    _seekableFullDurationSeconds = null;
    _seekOffsetSeconds = 0;
  }

  bool get canSeek => _seekableVideoId != null && _seekableFullDurationSeconds != null;

  Timer? _pollTimer;
  Timer? _displayTickTimer;
  Timer? _volumeDebounceTimer;
  Timer? _retryTimer;

  String get auxToggleTarget => nowPlaying?.source == 'BLUETOOTH' ? 'AUX' : 'BLUETOOTH';

  void setStatusMessage(String message) {
    statusMessage = message;
    notifyListeners();
  }

  Future<void> init() async {
    settings = await _settingsService.loadSettings();
    playlists = await _playlistService.loadPlaylists();
    notifyListeners();

    await _findSpeaker();
    unawaited(searchRadio(_defaultRadioQuery));
    unawaited(searchYoutube(_defaultYoutubeQuery));

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshStatus());

    _displayTickTimer?.cancel();
    _displayTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Freeze the smooth ticker whenever playback isn't actually advancing:
      // `playlistPaused` and `_manuallyPaused` are both local flags set
      // synchronously (before any awaited network call) the instant the user
      // taps pause, in playlistPlayPause and sendKey respectively - so
      // neither has to wait for the next poll to take effect.
      // `nowPlaying?.isPlaying` (playStatus == 'PLAY_STATE') catches every
      // other non-playing case, including stopped/buffering states.
      // The 5-second resync in refreshStatus() still exists as a backstop
      // for bounding drift on top of this - it just no longer has anything
      // to correct during an ordinary pause, so the visible "count up then
      // snap back down" sawtooth goes away.
      final actuallyPlaying = !playlistPaused && !_manuallyPaused && nowPlaying?.isPlaying == true;
      if (_displayElapsedSeconds != null && actuallyPlaying) {
        _displayElapsedSeconds = _displayElapsedSeconds! + 1;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _displayTickTimer?.cancel();
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
      // This poll's data is now authoritative for isPlaying - the optimistic
      // bridge flag has done its job (covering the gap between the tap and
      // this poll landing) and must not linger past it, or a later play
      // started through a path other than sendKey('PLAY') (a preset,
      // playlist track, custom URL, etc.) would stay frozen indefinitely.
      _manuallyPaused = false;
      speakerReachable = true;
      if (np.isPlaying) _displayConfirmedPlaying = true;
      // Resync the smooth display ticker to the real polled value every
      // time - this is what keeps interpolation drift bounded to at most
      // one poll interval, and immediately reflects a track change (new
      // elapsed=0) rather than waiting for the local ticker to catch up.
      // Gated on _displayConfirmedPlaying so a rising elapsed count reported
      // by the speaker WHILE STILL BUFFERING never reaches the display.
      if (_displayConfirmedPlaying) {
        _displayElapsedSeconds = np.elapsedSeconds;
      }
      if (!isDraggingVolume) {
        volumeStatus = vol;
        displayVolume = vol.actual;
      }
      if (activePlaylist != null) {
        await _evaluatePlaylistState();
      }
    } catch (_) {
      speakerReachable = false;
    }
    notifyListeners();
  }

  /// True position within the ORIGINAL track, accounting for any seek -
  /// after seeking, the speaker's own now_playing reports position within
  /// the TRIMMED/restarted stream (starting back at 0), not the original
  /// video's timeline, so this adds back the seek offset. Unaffected
  /// (offset stays 0) for anything that's never been seeked.
  int? get displayTrueElapsedSeconds {
    final elapsed = _displayElapsedSeconds;
    if (elapsed == null) return null;
    return _seekOffsetSeconds + elapsed;
  }

  int? get displayTrueTotalSeconds => _seekableFullDurationSeconds ?? nowPlaying?.totalSeconds;

  /// UI-facing "2:59 / 3:00" (or just "2:59" if duration's unknown) built
  /// from the smooth once-per-second ticker, not the raw 5-second-stale
  /// NowPlaying.elapsedSeconds - use this (not NowPlaying.progressText) for
  /// anything shown on screen.
  String? get displayProgressText {
    final elapsed = displayTrueElapsedSeconds;
    if (elapsed == null) return null;
    final total = displayTrueTotalSeconds;
    if (total == null || total <= 0) return NowPlaying.formatSeconds(elapsed);
    return '${NowPlaying.formatSeconds(elapsed)} / ${NowPlaying.formatSeconds(total)}';
  }

  double? get displayProgressFraction {
    final elapsed = displayTrueElapsedSeconds;
    final total = displayTrueTotalSeconds;
    if (elapsed == null || total == null || total <= 0) return null;
    return (elapsed / total).clamp(0.0, 1.0);
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
    if (activePlaylist != null) _stopPlaylistMode();
    // Set synchronously, BEFORE the awaited network round trip below, so the
    // display ticker freezes at the moment of the tap - see _manuallyPaused's
    // doc comment for why this can't just wait on nowPlaying to catch up.
    if (key == 'PAUSE') {
      _manuallyPaused = true;
      notifyListeners();
    } else if (key == 'PLAY') {
      _manuallyPaused = false;
      notifyListeners();
    }
    await _withStatus('', () async {
      await XmlApiClient.sendKey(ip, key);
      Timer(const Duration(milliseconds: 500), refreshStatus);
    });
  }

  Future<void> stop() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    if (activePlaylist != null) _stopPlaylistMode();
    await _withStatus('Stopping...', () async {
      await SoapClient.stop(ip);
      Timer(const Duration(milliseconds: 500), refreshStatus);
    });
  }

  Future<void> toggleAuxSource() async {
    final ip = speaker?.ip;
    if (ip == null) return;
    if (activePlaylist != null) _stopPlaylistMode();
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
    if (activePlaylist != null) _stopPlaylistMode();
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

  Future<void> playCustomUrl(String url, String label, {String? title, Duration? duration}) async {
    final ip = speaker?.ip;
    if (ip == null) return;
    if (activePlaylist != null) _stopPlaylistMode();
    // Otherwise the display ticker keeps counting up from the PREVIOUS
    // track's elapsed value for up to 5s, until the next poll resyncs it -
    // showing a stale/nonsensical progress readout for a new track.
    _displayElapsedSeconds = null;
    _displayConfirmedPlaying = false;
    // This is a new play command, so any leftover optimistic "manually
    // paused" freeze from a previous transport-row Pause tap no longer
    // applies - don't let it wrongly freeze the ticker for this new track
    // until the next poll happens to clear it.
    _manuallyPaused = false;
    // Default: most callers here (radio, custom URL) aren't seekable.
    // playYoutubeResult marks itself seekable right after calling this.
    _clearSeekable();
    await _withStatus('Loading $label...', () async {
      await SoapClient.play(ip, url, title: title, duration: duration);
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
    await playCustomUrl(
      url,
      '${r.title} (YouTube)',
      title: r.title,
      duration: r.durationSeconds != null ? Duration(seconds: r.durationSeconds!) : null,
    );
    _trackSeekableYoutube(r.id, r.durationSeconds);
  }

  /// Whether tapping a YouTube Music result should auto-advance through the
  /// rest of the current search results when each one finishes, instead of
  /// just playing that one track. Reuses the same playlist auto-advance
  /// machinery (see playPlaylistFrom/_evaluatePlaylistState) against an
  /// ephemeral, never-persisted "playlist" built from youtubeResults -
  /// no separate advance mechanism needed for this.
  bool youtubeAutoPlayNext = false;

  void toggleYoutubeAutoPlayNext() {
    youtubeAutoPlayNext = !youtubeAutoPlayNext;
    if (!youtubeAutoPlayNext) {
      // Turning it off must also stop an already-running ephemeral-playlist
      // auto-advance - flipping this flag alone doesn't touch activePlaylist,
      // so without this the poll-based state machine would keep advancing
      // through search results even after the toggle looks "off" in the UI.
      if (activePlaylist?.id == _ephemeralYoutubeResultsPlaylistId) {
        _stopPlaylistMode();
      }
    } else {
      // Turning it ON while a YouTube Music result is already playing (it
      // was started via the plain one-shot playYoutubeResult path, before
      // the toggle was on) should start auto-advance for THAT track once it
      // ends - not just for whatever gets tapped next.
      _adoptCurrentlyPlayingYoutubeResult();
    }
    notifyListeners();
  }

  static const _ephemeralYoutubeResultsPlaylistId = '_ephemeral_youtube_results';

  List<PlaylistTrack> _buildEphemeralYoutubeTracks() {
    return youtubeResults
        .map((r) => PlaylistTrack.youtube(
              videoId: r.id,
              title: r.title,
              imageUrl: r.thumbnailUrl,
              durationSeconds: r.durationSeconds,
            ))
        .toList();
  }

  Playlist _buildEphemeralYoutubePlaylist(List<PlaylistTrack> tracks) => Playlist(
        id: _ephemeralYoutubeResultsPlaylistId,
        name: 'YouTube Music',
        createdAt: 0,
        updatedAt: 0,
        tracks: tracks,
      );

  /// Plays youtubeResults[index], auto-advancing through the rest of the
  /// current search results afterward (as long as youtubeAutoPlayNext stays
  /// on and the results list itself doesn't change - a fresh search builds a
  /// new ephemeral playlist next time this is called).
  Future<void> playYoutubeResultAt(int index) async {
    if (index < 0 || index >= youtubeResults.length) return;
    final ephemeralPlaylist = _buildEphemeralYoutubePlaylist(_buildEphemeralYoutubeTracks());
    await playPlaylistFrom(ephemeralPlaylist, index);
  }

  /// Starts tracking an already-playing YouTube Music result as the active
  /// ephemeral-playlist entry, WITHOUT re-issuing SetAVTransportURI/Play
  /// (it's already playing - restarting it from 0 would be a jarring UX
  /// regression just for flipping a switch). No-ops if now_playing's
  /// location doesn't match anything in the current search results (e.g.
  /// nothing is playing, or it's a radio station/preset/custom URL instead).
  void _adoptCurrentlyPlayingYoutubeResult() {
    final loc = nowPlaying?.location;
    if (loc == null || !settings.isConfigured) return;
    final matchIndex =
        youtubeResults.indexWhere((r) => StreamUrlBuilder.youtube(settings.streamProxyUrl, r.id) == loc);
    if (matchIndex == -1) return;

    final tracks = _buildEphemeralYoutubeTracks();
    activePlaylist = _buildEphemeralYoutubePlaylist(tracks);
    _activeTrackId = tracks[matchIndex].id;
    playlistPaused = false;
    _lastCommandedLocation = loc;
    _confirmedStarted = nowPlaying?.isPlaying ?? false;
    _terminalStreak = 0;
    _ticksSinceCommand = 0;
    _lastElapsedSeconds = nowPlaying?.elapsedSeconds;
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

  // ===========================================================================
  // Playlist library (CRUD) - persisted via PlaylistService as one JSON blob.
  // ===========================================================================

  Future<void> _savePlaylists() async {
    await _playlistService.savePlaylists(playlists);
  }

  Future<Playlist> createPlaylist(String name) async {
    final playlist = Playlist.create(name);
    playlists = [...playlists, playlist];
    await _savePlaylists();
    notifyListeners();
    return playlist;
  }

  Future<void> renamePlaylist(String playlistId, String newName) async {
    playlists = playlists.map((p) => p.id == playlistId ? p.copyWith(name: newName) : p).toList();
    if (activePlaylist?.id == playlistId) {
      activePlaylist = playlists.firstWhere((p) => p.id == playlistId);
    }
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> deletePlaylist(String playlistId) async {
    playlists = playlists.where((p) => p.id != playlistId).toList();
    // A library edit isn't a transport command - if this playlist was
    // playing, stop tracking it as "active" but don't touch the speaker's
    // actual audio, so the user doesn't lose sound just for tidying up.
    if (activePlaylist?.id == playlistId) {
      _stopPlaylistMode();
    }
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> addYoutubeResultToPlaylist(String playlistId, YoutubeResult result) async {
    final track = PlaylistTrack.youtube(
      videoId: result.id,
      title: result.title,
      imageUrl: result.thumbnailUrl,
      durationSeconds: result.durationSeconds,
    );
    playlists = playlists.map((p) {
      if (p.id != playlistId) return p;
      return p.copyWith(tracks: [...p.tracks, track]);
    }).toList();
    if (activePlaylist?.id == playlistId) {
      activePlaylist = playlists.firstWhere((p) => p.id == playlistId);
    }
    await _savePlaylists();
    setStatusMessage('Added to playlist');
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    final activeIdBefore = _activeTrackId;
    final wasActiveTrack = activePlaylist?.id == playlistId && activeIdBefore == trackId;

    Playlist? updated;
    playlists = playlists.map((p) {
      if (p.id != playlistId) return p;
      updated = p.copyWith(tracks: p.tracks.where((t) => t.id != trackId).toList());
      return updated!;
    }).toList();

    if (activePlaylist?.id == playlistId && updated != null) {
      activePlaylist = updated;
      if (playlistOrder == PlaylistOrder.shuffle && _shuffleQueue != null) {
        _shuffleQueue = _shuffleQueue!.where((id) => id != trackId).toList();
      }
      if (wasActiveTrack) {
        // The entry that was actively playing just got removed from the
        // library - move on to whatever's next rather than leaving the
        // controller pointed at a track that no longer exists.
        await playlistNext();
      }
    }

    await _savePlaylists();
    notifyListeners();
  }

  Future<void> reorderPlaylistTrack(String playlistId, int oldIndex, int newIndex) async {
    playlists = playlists.map((p) {
      if (p.id != playlistId) return p;
      final tracks = [...p.tracks];
      final adjustedNewIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
      final item = tracks.removeAt(oldIndex);
      tracks.insert(adjustedNewIndex, item);
      return p.copyWith(tracks: tracks);
    }).toList();
    // Sequential mode re-derives play order live from Playlist.tracks, so a
    // reorder takes effect on the next advance automatically - nothing else
    // to update here. Shuffle mode's frozen _shuffleQueue is untouched by a
    // reorder, matching the design's "reorder changes what's next, not what's
    // already loaded" rule - shuffle order simply doesn't depend on list order.
    if (activePlaylist?.id == playlistId) {
      activePlaylist = playlists.firstWhere((p) => p.id == playlistId);
    }
    await _savePlaylists();
    notifyListeners();
  }

  bool isPlaylistTrackActive(PlaylistTrack track) {
    return activePlaylist != null && _activeTrackId == track.id;
  }

  // ===========================================================================
  // Playlist playback session - queue/shuffle/repeat + the poll-based
  // auto-advance state machine. No push notifications exist from the speaker
  // in this architecture, so "did the track end" is inferred from the
  // existing 5-second now_playing poll alone (see _evaluatePlaylistState).
  // ===========================================================================

  PlaylistTrack? get activeTrack {
    if (activePlaylist == null || _activeTrackId == null) return null;
    try {
      return activePlaylist!.tracks.firstWhere((t) => t.id == _activeTrackId);
    } catch (_) {
      return null;
    }
  }

  /// 1-based position for display (e.g. "Track 2 of 5").
  int get activeTrackDisplayPosition {
    if (activePlaylist == null || _activeTrackId == null) return 0;
    if (playlistOrder == PlaylistOrder.shuffle) return (_shuffleQueuePos ?? 0) + 1;
    final idx = activePlaylist!.tracks.indexWhere((t) => t.id == _activeTrackId);
    return idx == -1 ? 0 : idx + 1;
  }

  int get activeTrackCount => activePlaylist?.tracks.length ?? 0;

  Future<void> playPlaylistFrom(Playlist playlist, int trackIndex) async {
    if (speaker?.ip == null) return;
    if (trackIndex < 0 || trackIndex >= playlist.tracks.length) return;
    final startTrack = playlist.tracks[trackIndex];
    activePlaylist = playlist;
    _activeTrackId = startTrack.id;
    if (playlistOrder == PlaylistOrder.shuffle) {
      _shuffleQueue = _buildShuffleQueue(playlist, keepFirst: startTrack.id);
      _shuffleQueuePos = 0;
    } else {
      _shuffleQueue = null;
      _shuffleQueuePos = null;
    }
    playlistPaused = false;
    await _commandActiveTrack();
  }

  List<String> _buildShuffleQueue(Playlist playlist, {String? keepFirst}) {
    final ids = playlist.tracks.map((t) => t.id).toList()..shuffle();
    if (keepFirst != null && ids.remove(keepFirst)) {
      ids.insert(0, keepFirst);
    }
    return ids;
  }

  String _buildPlayableUrl(PlaylistTrack track) {
    switch (track.source) {
      case TrackSource.youtube:
        return StreamUrlBuilder.youtube(settings.streamProxyUrl, track.sourceId);
      case TrackSource.spotify:
        throw StateError('Spotify playback is not implemented yet');
    }
  }

  Future<void> _commandActiveTrack() async {
    final ip = speaker?.ip;
    final track = activeTrack;
    if (ip == null || track == null) {
      _stopPlaylistMode(message: 'Playlist finished.');
      return;
    }
    final url = _buildPlayableUrl(track);
    _lastCommandedLocation = url;
    _confirmedStarted = false;
    _terminalStreak = 0;
    _ticksSinceCommand = 0;
    _lastElapsedSeconds = null;
    // Otherwise the display ticker keeps counting up from the PREVIOUS
    // track's elapsed value for up to 5s, until the next poll resyncs it.
    _displayElapsedSeconds = null;
    _displayConfirmedPlaying = false;
    // See playCustomUrl's identical reset for why - a new track is starting,
    // so a stale manual-pause freeze must not carry over onto it.
    _manuallyPaused = false;
    if (track.source == TrackSource.youtube) {
      _trackSeekableYoutube(track.sourceId, track.durationMs != null ? track.durationMs! ~/ 1000 : null);
    } else {
      _clearSeekable();
    }
    statusMessage = 'Playing: ${track.title}';
    notifyListeners();
    try {
      await SoapClient.play(
        ip,
        url,
        title: track.title,
        duration: track.durationMs != null ? Duration(milliseconds: track.durationMs!) : null,
      );
    } catch (e) {
      statusMessage = 'Error: $e';
      notifyListeners();
    }
  }

  PlaylistTrack? _computeAdjacentTrack(int direction) {
    final playlist = activePlaylist;
    if (playlist == null) return null;

    if (playlistOrder == PlaylistOrder.shuffle) {
      final queue = _shuffleQueue;
      if (queue == null || queue.isEmpty) return null;
      var pos = (_shuffleQueuePos ?? 0) + direction;
      if (pos >= queue.length) {
        if (playlistRepeat == PlaylistRepeat.loop) {
          _shuffleQueue = _buildShuffleQueue(playlist);
          pos = 0;
        } else {
          return null;
        }
      } else if (pos < 0) {
        pos = playlistRepeat == PlaylistRepeat.loop ? queue.length - 1 : 0;
      }
      _shuffleQueuePos = pos;
      final id = _shuffleQueue![pos];
      try {
        return playlist.tracks.firstWhere((t) => t.id == id);
      } catch (_) {
        return null;
      }
    }

    final tracks = playlist.tracks;
    if (tracks.isEmpty) return null;
    final curIdx = tracks.indexWhere((t) => t.id == _activeTrackId);
    var nextIdx = (curIdx == -1 ? 0 : curIdx) + direction;
    if (nextIdx >= tracks.length) {
      if (playlistRepeat != PlaylistRepeat.loop) return null;
      nextIdx = 0;
    } else if (nextIdx < 0) {
      nextIdx = playlistRepeat == PlaylistRepeat.loop ? tracks.length - 1 : 0;
    }
    return tracks[nextIdx];
  }

  Future<void> playlistNext() async {
    if (activePlaylist == null) return;
    final next = _computeAdjacentTrack(1);
    if (next == null) {
      _stopPlaylistMode(message: 'Playlist finished.');
      return;
    }
    _activeTrackId = next.id;
    playlistPaused = false;
    await _commandActiveTrack();
  }

  Future<void> playlistPrevious() async {
    if (activePlaylist == null) return;
    final prev = _computeAdjacentTrack(-1);
    if (prev == null) return;
    _activeTrackId = prev.id;
    playlistPaused = false;
    await _commandActiveTrack();
  }

  /// Playlist-aware pause/resume - deliberately distinct from the generic
  /// [sendKey]/[stop] entry points, which cancel playlist mode on the
  /// assumption the user is doing something else. This one sets
  /// [playlistPaused] instead, so the poll-based end-detection in
  /// _evaluatePlaylistState knows to stand down rather than mistaking a
  /// deliberate pause for the track having ended.
  Future<void> playlistPlayPause() async {
    final ip = speaker?.ip;
    if (ip == null || activePlaylist == null) return;
    // Flip the flag and notify BEFORE the awaited call below (sendKey itself
    // issues two sequential awaited HTTP round trips) - otherwise
    // `playlistPaused` doesn't actually reflect the pause until both those
    // round trips finish, during which the display ticker (gated on this
    // flag) keeps counting up and then has to snap back down once
    // refreshStatus's resync catches up - the exact sawtooth this flag
    // exists to prevent, just moved to the tap edge instead of eliminated.
    if (playlistPaused) {
      playlistPaused = false;
      notifyListeners();
      await XmlApiClient.sendKey(ip, 'PLAY');
    } else {
      playlistPaused = true;
      notifyListeners();
      await XmlApiClient.sendKey(ip, 'PAUSE');
    }
    notifyListeners();
    Timer(const Duration(milliseconds: 500), refreshStatus);
  }

  /// "Seek" to [position] within the currently-playing YouTube track. Since
  /// the audio is a live transcode (no pre-existing indexed file to seek
  /// within), this works by restarting the stream-proxy request with a new
  /// ?start= offset - a brief reload, not an instant/seamless scrub. Does
  /// NOT cancel playlist mode (mirrors playlistPlayPause's reasoning): this
  /// is the user continuing to control the same track, not switching to
  /// something else, so activePlaylist/_activeTrackId stay untouched - only
  /// the tracking fields the auto-advance state machine reads get updated to
  /// match the new stream.
  Future<void> seekTo(Duration position) async {
    final ip = speaker?.ip;
    final videoId = _seekableVideoId;
    final fullDuration = _seekableFullDurationSeconds;
    if (ip == null || videoId == null || fullDuration == null || !settings.isConfigured) return;

    final offsetSeconds = position.inSeconds.clamp(0, fullDuration);
    final url = StreamUrlBuilder.youtube(settings.streamProxyUrl, videoId, startSeconds: offsetSeconds);
    final remainingSeconds = fullDuration - offsetSeconds;

    _seekOffsetSeconds = offsetSeconds;
    _displayElapsedSeconds = null;
    _displayConfirmedPlaying = false;
    _manuallyPaused = false;

    if (activePlaylist != null) {
      _lastCommandedLocation = url;
      _confirmedStarted = false;
      _terminalStreak = 0;
      _ticksSinceCommand = 0;
      _lastElapsedSeconds = null;
    }

    await _withStatus('Seeking...', () async {
      await SoapClient.play(
        ip,
        url,
        title: nowPlaying?.track,
        duration: remainingSeconds > 0 ? Duration(seconds: remainingSeconds) : null,
      );
      Timer(const Duration(milliseconds: 1500), refreshStatus);
    });
  }

  void setPlaylistOrder(PlaylistOrder order) {
    if (playlistOrder == order) return;
    playlistOrder = order;
    if (activePlaylist != null) {
      if (order == PlaylistOrder.shuffle) {
        _shuffleQueue = _buildShuffleQueue(activePlaylist!, keepFirst: _activeTrackId);
        _shuffleQueuePos = 0;
      } else {
        _shuffleQueue = null;
        _shuffleQueuePos = null;
      }
    }
    notifyListeners();
  }

  void togglePlaylistRepeat() {
    playlistRepeat = playlistRepeat == PlaylistRepeat.once ? PlaylistRepeat.loop : PlaylistRepeat.once;
    notifyListeners();
  }

  /// Explicit user-initiated exit (e.g. a "stop playlist" action) - stops
  /// tracking playlist state without sending any transport command, so
  /// whatever's currently playing keeps playing until the user does
  /// something else.
  void exitPlaylistMode() => _stopPlaylistMode(message: 'Exited playlist mode.');

  void _stopPlaylistMode({String? message}) {
    activePlaylist = null;
    _activeTrackId = null;
    _shuffleQueue = null;
    _shuffleQueuePos = null;
    playlistPaused = false;
    _lastCommandedLocation = null;
    _confirmedStarted = false;
    _terminalStreak = 0;
    _ticksSinceCommand = 0;
    _lastElapsedSeconds = null;
    if (message != null) statusMessage = message;
    notifyListeners();
  }

  /// Runs once per 5-second poll tick (from refreshStatus) while a playlist
  /// is active. This is the entire "did the track end" mechanism - there is
  /// no push signal from the speaker to lean on instead.
  Future<void> _evaluatePlaylistState() async {
    if (playlistPaused) return;
    final track = activeTrack;
    if (track == null) {
      // The active entry no longer exists in the playlist (removed
      // elsewhere) - move on rather than getting stuck.
      await playlistNext();
      return;
    }
    final commanded = _lastCommandedLocation;
    if (commanded == null) return;
    final loc = nowPlaying?.location;
    final status = nowPlaying?.playStatus;
    final elapsed = nowPlaying?.elapsedSeconds;

    if (loc != commanded) {
      // Something else changed the source without going through this
      // controller (a physical panel button, Bluetooth, the Bose app used
      // concurrently). Fighting a concurrent human input by re-asserting
      // the URI would feel broken, not smart - cede control instead.
      _stopPlaylistMode(message: 'Playlist stopped (source changed).');
      return;
    }

    if (!_confirmedStarted) {
      _ticksSinceCommand++;
      if (status == 'PLAY_STATE' || (elapsed != null && elapsed > 0)) {
        _confirmedStarted = true;
        _terminalStreak = 0;
        _lastElapsedSeconds = elapsed;
      } else if (_ticksSinceCommand >= 6) {
        // Stall safety net: never confirmed playing within ~30s - treat as
        // a broken/unplayable entry rather than silently stalling forever.
        statusMessage = 'Skipped unplayable track: ${track.title}';
        await playlistNext();
      }
      return;
    }

    // When we actually told the speaker the track's real duration (via
    // DIDL-Lite metadata in SoapClient.play), now_playing's total is real -
    // reaching it is exact and immediate, no heuristic/debounce needed at
    // all. -1 second of slack accounts for polling only every 5s (we might
    // observe elapsed a couple seconds shy of total on the very last poll
    // before it naturally would have hit exactly total).
    if (nowPlaying?.hasKnownDuration == true && elapsed != null) {
      final total = nowPlaying!.totalSeconds!;
      if (elapsed >= total - 1) {
        await playlistNext();
        return;
      }
    }

    // Elapsed time actually advancing since the last poll is the strongest
    // available signal that audio is genuinely still flowing - trust it over
    // playStatus entirely. The full set of transient non-PLAY_STATE values
    // this device reports during normal playback (e.g. a brief re-buffer)
    // isn't fully known, and playStatus-only detection was firing false
    // "ended" positives during a song's own intro. Elapsed time can't lie
    // about this the way a possibly-unrecognized status string can.
    if (elapsed != null && _lastElapsedSeconds != null && elapsed > _lastElapsedSeconds!) {
      _lastElapsedSeconds = elapsed;
      _terminalStreak = 0;
      return;
    }
    if (elapsed != null) _lastElapsedSeconds = elapsed;

    if (status == 'PLAY_STATE' || status == 'BUFFERING_STATE') {
      _terminalStreak = 0;
      return;
    }

    // Require the non-playing state to persist across two consecutive polls
    // (~10s) before treating it as "really ended" - cheap insurance against
    // a transient network hiccup masquerading as a real end-of-track.
    _terminalStreak++;
    if (_terminalStreak >= 2) {
      await playlistNext();
    }
  }
}
