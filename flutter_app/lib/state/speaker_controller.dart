import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/app_settings.dart';
import '../models/group_info.dart';
import '../models/search_result.dart';
import '../models/speaker_info.dart';
import '../models/zone_info.dart';
import '../services/discovery.dart';
import '../services/fake_speaker_server.dart';
import '../services/preset_button_relay_service.dart';
import '../services/settings_service.dart';
import '../services/soap_client.dart';
import '../services/tunein_api_client.dart';
import '../services/xml_api_client.dart';
import 'speaker_session.dart';

export 'speaker_session.dart' show SpeakerSession;

const _defaultRadioQuery = 'Top 40';

/// One unit of playback control - either a solo connected speaker, or a
/// stereo-paired LEFT+RIGHT duo presented as one unit. This is a derived
/// view (see SpeakerController.playbackTargets), not independent state - it
/// has no existence beyond "the current pairing shape of `sessions`", so it
/// lives here next to its one producer rather than as its own model.
class PlaybackTarget {
  final List<SpeakerSession> members; // length 1 (solo) or 2 ([left, right])

  PlaybackTarget.solo(SpeakerSession session) : members = [session];
  PlaybackTarget.paired({required SpeakerSession left, required SpeakerSession right}) : members = [left, right];

  bool get isPaired => members.length == 2;
  SpeakerSession get left => members[0];
  SpeakerSession get right => members[1];
  SpeakerSession get solo => members[0];

  /// Whichever member's deviceId matches the group's masterDeviceId - NOT
  /// assumed to be `left`, since a pair created outside this app (the
  /// physical Bose app, a different phone) could have either role as master.
  SpeakerSession get commandTarget {
    if (!isPaired) return solo;
    final master = left.group?.masterDeviceId;
    return members.firstWhere((m) => m.speaker.deviceId == master, orElse: () => left);
  }

  String get id => isPaired ? '${left.id}+${right.id}' : solo.id;
  String get displayName => isPaired ? '${left.speaker.name} + ${right.speaker.name}' : solo.speaker.name;
}

/// The single ChangeNotifier for this app - deliberately not split into
/// Bloc/Riverpod layers, and not split per-speaker into N ChangeNotifiers
/// either: the state surface is still small enough (a list of speaker
/// sessions, two global search lists, a shared playlist library) that one
/// class keeps every cross-cutting concern (e.g. "don't clobber the volume
/// slider mid-drag", "a library edit can affect more than one connected
/// speaker's active-playlist mirror") in one obvious place. Per-speaker
/// playback state itself lives on [SpeakerSession] - see sessions below.
class SpeakerController extends ChangeNotifier {
  final _discovery = Discovery();
  final _settingsService = SettingsService();

  DiscoveryStatus discoveryStatus = DiscoveryStatus.idle;
  String discoveryMessage = '';

  /// One entry per currently-connected speaker.
  List<SpeakerSession> sessions = [];

  /// Speakers discovery has found but the user hasn't explicitly connected
  /// yet - a scan finding 3 speakers must not silently connect to all 3, so
  /// these just sit here (shown with a "Connect" action) until the user
  /// picks one via [connectToSpeaker]. Not persisted - only [sessions] is.
  List<SpeakerInfo> availableSpeakers = [];

  SpeakerSession? sessionById(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// deviceId -> the name this app itself already knows for that speaker
  /// (from a past rename or a prior connect), kept in sync by
  /// [_persistSessions] and seeded from the persisted cache at startup (see
  /// [_findSpeakers]). This - not whatever a fresh /info probe/scan reports -
  /// is the source of truth for a speaker's display name: renaming a
  /// speaker sends the new name to the device too (XmlApiClient.setName in
  /// [renameSpeaker]), but that write has the same "accepted with 200 but
  /// silently not committed" firmware race already documented elsewhere in
  /// this file (see refreshStatus's commandInFlight poll-skip doc comment) -
  /// so a fresh discovery
  /// probe/scan reporting the device's own (possibly stale) name must never
  /// be allowed to silently overwrite a name this app already knows,
  /// otherwise a rename that didn't actually stick on the hardware looks to
  /// the user like the app itself "forgot" it. Confirmed as a real reported
  /// issue, 2026-08-13.
  final Map<String, String> _knownNames = {};

  /// Applies [_knownNames]'s record for [info]'s device, if any, instead of
  /// trusting the device-reported name in [info] - see [_knownNames]' own
  /// doc comment. A device with no known name yet (never seen before) falls
  /// through unchanged.
  SpeakerInfo _withKnownName(SpeakerInfo info) {
    final known = _knownNames[info.deviceId];
    if (known == null || known == info.name) return info;
    return SpeakerInfo(ip: info.ip, deviceId: info.deviceId, name: known);
  }

  static String _infoId(SpeakerInfo info) => info.deviceId.isNotEmpty ? info.deviceId : info.ip;

  /// Adds [info] to [availableSpeakers] unless it's already there or already
  /// connected. Returns whether it was newly added.
  bool _addAvailable(SpeakerInfo info) {
    final id = _infoId(info);
    if (sessions.any((s) => s.id == id)) return false;
    if (availableSpeakers.any((a) => _infoId(a) == id)) return false;
    availableSpeakers = [...availableSpeakers, info];
    return true;
  }

  /// Explicit user action: turns an entry in [availableSpeakers] into a real
  /// connected [SpeakerSession]. Dev-preview entries (see
  /// previewWithoutSpeaker) are identified by their deviceId prefix so they
  /// still skip persistence once connected, same as before - and additionally
  /// get a real (loopback-only) FakeSpeakerServer started for them here, so
  /// they actually respond to play/pause/volume/preset/pairing commands
  /// instead of just sitting there unreachable.
  Future<void> connectToSpeaker(SpeakerInfo info) async {
    availableSpeakers = availableSpeakers.where((a) => a.ip != info.ip).toList();
    notifyListeners();
    final isDevPreview = info.deviceId.startsWith('dev-preview-');
    if (isDevPreview && !kIsWeb) {
      try {
        final fake = FakeSpeakerServer(ip: info.ip, deviceId: info.deviceId, name: info.name);
        await fake.start();
        _fakeServers[info.deviceId] = fake;
      } catch (e) {
        statusMessage = 'Could not start fake speaker: $e';
        notifyListeners();
      }
    }
    await _addSession(info, isDevPreview: isDevPreview);
  }

  /// Computed fresh on every access, never stored - the current pairing
  /// shape of [sessions] can never drift out of sync with this, since there
  /// is no separate copy to drift. Cheap at realistic session counts (2-6);
  /// callers should read it once per build rather than repeatedly.
  ///
  /// Pairing requires MUTUAL reciprocity - session A and B become one
  /// [PlaybackTarget] only if A's group names B back AND B's group names A
  /// back. One-sided/stale state (e.g. mid-transition just after an external
  /// unpair via the physical Bose app, where the two sessions' independent
  /// 5s poll timers haven't both landed yet) falls back to both being solo
  /// targets - never a half-ghost merged card.
  List<PlaybackTarget> get playbackTargets {
    final result = <PlaybackTarget>[];
    final consumed = <String>{};
    for (final s in sessions) {
      if (consumed.contains(s.id)) continue;
      GroupRole? partnerRole;
      for (final r in s.group?.roles ?? const <GroupRole>[]) {
        if (r.deviceId != s.speaker.deviceId) {
          partnerRole = r;
          break;
        }
      }
      final partner = partnerRole == null ? null : sessionById(partnerRole.deviceId);
      final partnerConfirms = partner?.group?.roles.any((r) => r.deviceId == s.speaker.deviceId) ?? false;
      if (partner != null && partnerConfirms && !consumed.contains(partner.id)) {
        // Master (commandTarget) unreachable for 2+ polls -> split into two
        // ordinary solos instead of a merged card with a dead command path;
        // this reuses the existing unreachable-card UI with no new code.
        final masterId = s.group!.masterDeviceId;
        final master = s.speaker.deviceId == masterId ? s : (partner.speaker.deviceId == masterId ? partner : s);
        if (master.unreachableStreak >= 2) {
          result.add(PlaybackTarget.solo(s));
          result.add(PlaybackTarget.solo(partner));
        } else {
          final leftSession = s.group!.roles.firstWhere((r) => r.deviceId == s.speaker.deviceId).role == StereoRole.left ? s : partner;
          final rightSession = leftSession == s ? partner : s;
          result.add(PlaybackTarget.paired(left: leftSession, right: rightSession));
        }
        consumed.add(s.id);
        consumed.add(partner.id);
        continue;
      }
      result.add(PlaybackTarget.solo(s));
      consumed.add(s.id);
    }
    return result;
  }

  AppSettings settings = const AppSettings();

  List<RadioResult> radioResults = [];
  bool radioLoading = false;
  String? radioError;

  /// The query that produced the CURRENT [radioResults] - set at the very
  /// top of [searchRadio], before any of its async work, so the UI can tell
  /// (via [radioResultsAreDefault]) whether the user has ever actually
  /// searched, or the search box/grid should stay in its untouched initial
  /// state (see [_defaultRadioQuery], never searched automatically).
  String lastRadioQuery = _defaultRadioQuery;

  /// Standard "browse by genre" rows shown on the TuneIn tab, same pattern
  /// as most radio-directory apps (a row per genre, each independently
  /// loaded/cached) - fixed list rather than user-configurable for now.
  static const genres = ['Rock', 'Pop', 'Jazz', 'News', 'Classical'];

  /// genre -> that genre's raw search results (unfiltered - see
  /// [visibleGenreResults] for the https-filtered view the UI should
  /// actually use, same as [visibleRadioResults] does for the main list).
  final Map<String, List<RadioResult>> genreResults = {};
  final Map<String, bool> genreLoading = {};

  Future<void> _loadGenreRecommendations() async {
    await Future.wait(genres.map((genre) async {
      genreLoading[genre] = true;
      notifyListeners();
      try {
        final results = await TuneInApiClient.search(genre);
        genreResults[genre] = results;
        _prefetchRadioUrls(results);
      } catch (_) {
        // Leave whatever this genre had before (if anything) - same
        // "don't blank out on a transient failure" reasoning as searchRadio.
      } finally {
        genreLoading[genre] = false;
        notifyListeners();
      }
    }));
  }

  /// Same https-unplayable filtering as [visibleRadioResults], scoped to one
  /// genre row.
  List<RadioResult> visibleGenreResults(String genre) =>
      (genreResults[genre] ?? []).where((r) => !unplayableStationIds.contains(r.id)).toList();

  /// Most-recently-played stations across all sessions/searches, most recent
  /// first - the standard "Recently Played" row every radio-directory app
  /// has. Persisted locally (see SettingsService) so it survives app
  /// restarts, same as the known speaker list.
  List<RadioResult> recentlyPlayed = [];
  static const _maxRecentlyPlayed = 20;

  Future<void> _addToRecentlyPlayed(RadioResult r) async {
    recentlyPlayed = [r, ...recentlyPlayed.where((e) => e.id != r.id)].take(_maxRecentlyPlayed).toList();
    notifyListeners();
    try {
      await _settingsService.saveRecentlyPlayed(recentlyPlayed);
    } catch (_) {
      // Best-effort, same as every other background persistence call in
      // this file - this is a fire-and-forget call (see playRadioResult),
      // so a failure here has no other catcher; letting it escape would
      // surface as an unhandled async error for what's just a nice-to-have
      // history list, not a critical action.
    }
  }

  /// User-curated favorites - unlike the physical preset 1-6 slots (see
  /// PanelControl's own _PresetHitBox doc comment), this never touches the
  /// speaker at all: it's pure local app state, so saving/recalling a
  /// station here is always instant and reliable, with no dependency on the
  /// device's own finicky preset persistence. This is the app-side answer to
  /// "save this station for later" now that the in-app preset-save gesture
  /// has been removed - saving to an actual physical preset button is a
  /// physical-only action from here on.
  List<RadioResult> favorites = [];

  bool isFavorite(RadioResult r) => favorites.any((e) => e.id == r.id);

  Future<void> toggleFavorite(RadioResult r) async {
    favorites = isFavorite(r) ? favorites.where((e) => e.id != r.id).toList() : [...favorites, r];
    notifyListeners();
    try {
      await _settingsService.saveFavorites(favorites);
    } catch (_) {
      // Best-effort - see _addToRecentlyPlayed's own doc comment.
    }
  }

  // ===========================================================================
  // "Stream on Your Phone" - lets someone with no physical SoundTouch speaker
  // (or who just wants sound out of the device in their hand right now) play
  // TuneIn stations directly through THIS device's own speaker, using the
  // exact same search/genre/recently-played/favorites lists as every other
  // playback target - it's simply another destination those "Play" taps can
  // route to. Deliberately NOT built on SpeakerSession/PlaybackTarget: those
  // model a real networked device reachable at an IP over the SoundTouch XML/
  // SOAP API, and this is neither - it's real local audio decode+output via
  // just_audio, so it needs its own small, parallel bit of state instead of
  // being shoehorned into the real-speaker machinery (and, unlike a real
  // speaker, never goes "unreachable" or needs polling - it's always exactly
  // as available as the app process itself is).
  // ===========================================================================

  /// True once the user has tapped "Stream on Your Phone" - never reset back
  /// to false automatically (there's no "disconnect" concept for the phone
  /// itself the way there is for a real speaker), so once enabled the Player
  /// page always has a phone-streaming card available, independent of
  /// however many real speakers are also connected.
  bool phoneStreamingEnabled = false;

  // late, not eager - constructing a real AudioPlayer touches platform
  // channels (AudioSession's own method channel setup), which needs
  // WidgetsFlutterBinding initialized first. Plenty of tests (and most real
  // sessions, which never touch phone-streaming at all) construct a
  // SpeakerController without that binding set up - eager construction here
  // broke every one of them the instant this field was added. Deferring
  // until first real use (see enablePhoneStreaming) means a
  // SpeakerController that never streams to the phone never constructs one
  // at all.
  late final AudioPlayer _phonePlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _phonePlayerStateSub;

  RadioResult? phoneNowPlaying;
  bool get phoneIsPlaying => _phonePlayer.playing;

  void enablePhoneStreaming() {
    if (phoneStreamingEnabled) return;
    phoneStreamingEnabled = true;
    // Rebroadcasts as SpeakerController's own notifyListeners() so the
    // player card updates on state changes that don't originate from a
    // direct tap here (buffering -> playing, a stream erroring out, etc.) -
    // the same reason a real SpeakerSession polls rather than only updating
    // optimistically on commanded actions.
    _phonePlayerStateSub = _phonePlayer.playerStateStream.listen((_) => notifyListeners());
    // Guarded on emptiness - re-enabling after a disablePhoneStreaming()
    // (see its own doc comment: that only turns the flag off, it never
    // clears phoneGenreResults) would otherwise re-fetch all four rows from
    // scratch on every toggle, even though what's already cached is still
    // perfectly good.
    if (phoneGenreResults.isEmpty) unawaited(_loadPhoneRecommendations());
    notifyListeners();
  }

  /// Removes the Phone Streaming card from the Player page and, since
  /// phoneStreamingEnabled gates the "Stream on Your Phone" button on the
  /// Speakers screen (see SearchingOverlay), naturally makes that button
  /// available to tap again there. Stops playback but deliberately does NOT
  /// dispose _phonePlayer - it's `late final`, so this instance is the only
  /// one this SpeakerController will ever have; re-enabling later (a fresh
  /// tap on that same button) reuses it rather than needing a disposed
  /// player replaced.
  Future<void> disablePhoneStreaming() async {
    if (!phoneStreamingEnabled) return;
    await _phonePlayer.stop();
    await _phonePlayerStateSub?.cancel();
    _phonePlayerStateSub = null;
    phoneNowPlaying = null;
    phoneStreamingEnabled = false;
    notifyListeners();
  }

  bool isPhonePlaying(RadioResult r) => phoneIsPlaying && phoneNowPlaying?.id == r.id;

  /// 0-100, matching every other volume control in this app (VolumeSlider),
  /// even though just_audio's own scale is a 0.0-1.0 double - converted at
  /// this boundary so the UI layer never has to think about the difference.
  /// Local audio volume, unlike a real speaker's, has no network round-trip
  /// cost - no debounce/optimistic-drag dance needed the way
  /// onVolumeInput/onVolumeChange do for VolumeSlider, a plain set suffices.
  int get phoneVolume => (_phonePlayer.volume * 100).round();

  void setPhoneVolume(int value) {
    _phonePlayer.setVolume(value.clamp(0, 100) / 100);
    notifyListeners();
  }

  Future<void> playOnPhone(RadioResult r) async {
    final url = await _resolvePhoneRadioUrl(r.id);
    if (url == null) {
      setStatusMessage('Could not play "${r.name}" - this station is not available right now.');
      return;
    }
    unawaited(_addToRecentlyPlayed(r));
    phoneNowPlaying = r;
    notifyListeners();
    try {
      await _phonePlayer.setUrl(url);
      await _phonePlayer.play();
    } catch (_) {
      setStatusMessage('Could not play "${r.name}" on this device.');
    }
  }

  /// Own resolve+cache path for phone playback, deliberately separate from
  /// [_resolveRadioUrl]/[_radioUrlCache] - those exist to serve the physical
  /// speaker, which cannot play https:// streams at all (see
  /// TuneInApiClient.resolveStreamUrl's doc comment), so a station found to
  /// be https gets permanently marked in [unplayableStationIds] and hidden
  /// from view. Sharing that cache/set here would wrongly taint a station as
  /// globally unplayable (or silently hand the speaker path an https URL
  /// that was only ever validated for the phone) just because someone
  /// streamed it to their phone first. This path never rejects https and
  /// never touches [unplayableStationIds] at all.
  final Map<String, ({String url, DateTime at})> _phoneRadioUrlCache = {};

  @visibleForTesting
  Future<String?> Function(String stationId) resolvePhoneRadioUrl = TuneInApiClient.resolveStreamUrlForPhone;

  Future<String?> _resolvePhoneRadioUrl(String stationId) async {
    final cached = _phoneRadioUrlCache[stationId];
    if (cached != null && DateTime.now().difference(cached.at) < _radioUrlCacheTtl) {
      return cached.url;
    }
    final url = await resolvePhoneRadioUrl(stationId);
    if (url != null) _phoneRadioUrlCache[stationId] = (url: url, at: DateTime.now());
    return url;
  }

  /// "Browse by region/genre" rows shown specifically in the Phone Streaming
  /// player card - a different, smaller set than [genres] (used by the
  /// TuneIn tab and each physical speaker's own card) since the user asked
  /// for exactly these four. Map value is the actual TuneIn search query;
  /// the map KEY is the short label shown in the UI ("PH"/"US" read better
  /// as row headers than "Philippines"/"USA" would).
  static const phoneRecommendations = {'Pop': 'Pop', 'Rock': 'Rock', 'PH': 'Philippines', 'US': 'USA'};

  final Map<String, List<RadioResult>> phoneGenreResults = {};
  final Map<String, bool> phoneGenreLoading = {};

  /// Unlike [_loadGenreRecommendations] (fired unconditionally from [init]),
  /// this only ever runs once phone-streaming is actually turned on (see
  /// [enablePhoneStreaming]) - no reason to spend network calls on
  /// recommendations for a feature the user hasn't opted into.
  Future<void> _loadPhoneRecommendations() async {
    await Future.wait(phoneRecommendations.entries.map((entry) async {
      final label = entry.key;
      phoneGenreLoading[label] = true;
      notifyListeners();
      try {
        // Deliberately NOT filtered by unplayableStationIds (see
        // phoneGenreResults' own doc comment above it) - every result stays
        // visible here, https included, since just_audio has no trouble
        // with any of them.
        phoneGenreResults[label] = await TuneInApiClient.search(entry.value);
      } catch (_) {
        // Leave whatever this row had before (if anything) - same
        // "don't blank out on a transient failure" reasoning as searchRadio.
      } finally {
        phoneGenreLoading[label] = false;
        notifyListeners();
      }
    }));
  }

  Future<void> phoneTogglePlayPause() async {
    if (phoneNowPlaying == null) return;
    if (_phonePlayer.playing) {
      await _phonePlayer.pause();
    } else {
      await _phonePlayer.play();
    }
  }

  /// Steps to the next/previous entry in [recentlyPlayed] relative to
  /// whatever's currently playing (wrapping both ends) - the simplest real,
  /// bounded "queue" already available anywhere in the app, rather than
  /// inventing a whole separate playlist concept just for these two buttons.
  Future<void> phoneSkip({required bool forward}) async {
    if (recentlyPlayed.isEmpty) return;
    final currentIndex = phoneNowPlaying == null ? -1 : recentlyPlayed.indexWhere((e) => e.id == phoneNowPlaying!.id);
    final base = currentIndex == -1 ? 0 : currentIndex;
    final next = (base + (forward ? 1 : -1)) % recentlyPlayed.length;
    await playOnPhone(recentlyPlayed[next < 0 ? next + recentlyPlayed.length : next]);
  }

  /// Global toast for library-level / pre-speaker actions (e.g. "Could not
  /// reach a SoundTouch speaker at $ip", "Added to playlist"). Per-speaker
  /// action feedback ("Playing preset 2...") lives on SpeakerSession.statusMessage
  /// instead, so each card can show its own status independently.
  String statusMessage = '';

  Timer? _retryTimer;
  /// Consecutive _scanForSpeakers retries since the last fully-resolved
  /// scan - drives the 10s-then-60s backoff (see _scanForSpeakers). Reset
  /// to 0 whenever a scan resolves every known session.
  int _scanRetryAttempts = 0;
  int _devPreviewCounter = 0;

  /// Fake devices backing connected dev-preview sessions (see
  /// connectToSpeaker), keyed by deviceId - stopped in forgetSpeaker/dispose
  /// so no loopback HTTP listeners leak past the session that owns them.
  final Map<String, FakeSpeakerServer> _fakeServers = {};

  void setStatusMessage(String message) {
    statusMessage = message;
    notifyListeners();
  }

  Future<void> init() async {
    settings = await _settingsService.loadSettings();
    recentlyPlayed = await _settingsService.loadRecentlyPlayed();
    favorites = await _settingsService.loadFavorites();

    await _findSpeakers();
    unawaited(_loadGenreRecommendations());
  }

  @override
  void dispose() {
    for (final s in sessions) {
      s.cancelTimers();
    }
    for (final fake in _fakeServers.values) {
      fake.stop();
    }
    _retryTimer?.cancel();
    _phonePlayerStateSub?.cancel();
    // Guarded on phoneStreamingEnabled (not unconditional) - _phonePlayer is
    // `late`, so merely referencing it here would construct one for the
    // first time on every dispose(), even for a SpeakerController that never
    // streamed to the phone at all (see the field's own doc comment).
    if (phoneStreamingEnabled) _phonePlayer.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Discovery - finds every SoundTouch speaker on the LAN, not just one.
  // ===========================================================================

  Future<void> _findSpeakers() async {
    _retryTimer?.cancel();
    final cached = await _settingsService.loadCachedSpeakers();
    // Seed _knownNames from the persisted cache BEFORE probing anything -
    // _persistSessions only starts keeping it in sync once a session exists
    // in THIS process, so without this the very first reconnect of a
    // process's life would have nothing to fall back on yet.
    for (final c in cached) {
      if (c.deviceId.isNotEmpty) _knownNames[c.deviceId] = c.name;
    }
    if (cached.isNotEmpty) {
      discoveryStatus = DiscoveryStatus.checkingCached;
      discoveryMessage = 'Checking last known speaker(s)...';
      notifyListeners();
      final results = await Future.wait(cached.map((c) => _discovery.probeKnownIp(c.ip)));
      for (final info in results) {
        if (info != null) await _addSession(_withKnownName(info));
      }
    }
    // Always follow up with a full scan, even after a successful cached-IP
    // reconnect - this picks up any speaker not in the cache (new on the
    // network, or a cached one whose IP changed and dropped out).
    await _scanForSpeakers();
  }

  /// Finds speakers and lists them in [availableSpeakers] - never connects
  /// automatically, even to a speaker this app already knows about from a
  /// previous scan. Connecting is always an explicit user action via
  /// [connectToSpeaker] (the cached-speaker fast path in [_findSpeakers] is
  /// the one exception - those were already explicitly connected in a past
  /// session, so reconnecting to them on relaunch isn't a surprise).
  Future<void> _scanForSpeakers() async {
    final hadAnything = sessions.isNotEmpty || availableSpeakers.isNotEmpty;
    if (hadAnything) {
      statusMessage = 'Searching for additional speakers...';
    } else {
      discoveryStatus = DiscoveryStatus.scanning;
      discoveryMessage = 'Searching for speakers...';
    }
    notifyListeners();

    final found = await _discovery.scanSubnet(
      onStatus: (msg) {
        if (!hadAnything) {
          discoveryMessage = msg;
          notifyListeners();
        }
      },
    );

    var addedCount = 0;
    var relocatedCount = 0;
    // Ids relocated THIS pass - already confirmed reachable by the scan
    // itself (scanSubnet only returns HTTP-confirmed candidates), even
    // though the async refreshStatus kicked off below hasn't landed yet and
    // so session.speakerReachable hasn't flipped to true itself yet.
    final relocatedIds = <String>{};
    for (final info in found) {
      final id = _infoId(info);
      final existingSession = sessionById(id);
      if (existingSession != null) {
        // Same already-trusted device, found at a different address (e.g.
        // its DHCP lease changed) - update in place rather than silently
        // discarding this scan result, which would otherwise leave the
        // session pointed at a dead IP forever with no way back except
        // manually forgetting it and re-adding the new IP by hand.
        if (existingSession.speaker.ip != info.ip) {
          existingSession.speaker = _withKnownName(info);
          relocatedIds.add(id);
          relocatedCount++;
          unawaited(_persistSessions());
          unawaited(refreshStatus(existingSession));
          // PresetButtonRelayService.speakerIp is set once, at construction -
          // it has no way to notice existingSession.speaker being mutated in
          // place above, so without restarting it here it would keep
          // retrying the OLD (now dead) IP forever, exactly the same
          // stale-IP-forever failure mode the PC-side preset-listener.ps1
          // had before its own self-heal fix. _startSessionTimers already
          // does the stop-old/start-new dance (see its own doc comment) -
          // reusing it here is simpler than duplicating that logic just for
          // the relay.
          _startSessionTimers(existingSession);
        }
        continue;
      }
      if (_addAvailable(_withKnownName(info))) addedCount++;
    }

    // "Done" means every KNOWN session is actually reachable right now -
    // NOT just "at least one session/speaker exists somewhere" (the
    // previous check). That old check meant a stale session left over from
    // before a speaker was factory-reset/re-provisioned (still present in
    // `sessions`, just pointed at a now-dead IP) made this stop retrying
    // immediately on the very next scan, even though THAT session was
    // never actually resolved - confirmed as a real, reported incident,
    // 2026-07-22: WiFi setup completing successfully, but the app's
    // pre-existing entry for that speaker silently stuck on its old IP
    // until a manual rescan.
    final allResolved = sessions.every((s) => s.speakerReachable || relocatedIds.contains(s.id));

    if (allResolved && (sessions.isNotEmpty || availableSpeakers.isNotEmpty)) {
      _scanRetryAttempts = 0;
      discoveryStatus = DiscoveryStatus.found;
      if (hadAnything) {
        final parts = [
          if (addedCount > 0) '$addedCount new speaker(s)',
          if (relocatedCount > 0) '$relocatedCount speaker(s) reconnected at a new address',
        ];
        statusMessage = parts.isEmpty ? 'No new speakers found.' : 'Found ${parts.join(', ')}.';
      }
      notifyListeners();
      return;
    }

    // Backoff, never gives up entirely - a speaker that takes longer than
    // expected to rejoin (a slow DHCP lease, a router hiccup, etc.) still
    // needs to be found eventually with zero user action, not just within
    // an arbitrary first-few-tries window. Fast retries (10s) for the first
    // ~2 minutes cover the common "just finished WiFi setup" case without a
    // visible delay; after that this settles into a much cheaper 60s
    // cadence indefinitely, until every session resolves or the user
    // forgets it (see forgetSpeaker) - that's the actual "give up" switch,
    // not a retry-count ceiling here.
    _scanRetryAttempts++;
    final retryDelay = _scanRetryAttempts <= 12 ? const Duration(seconds: 10) : const Duration(seconds: 60);
    discoveryStatus = DiscoveryStatus.retrying;
    discoveryMessage = sessions.isEmpty && availableSpeakers.isEmpty
        ? 'No speaker found. Retrying in ${retryDelay.inSeconds}s...'
        : 'Still trying to reconnect... (retrying in ${retryDelay.inSeconds}s)';
    notifyListeners();
    _retryTimer = Timer(retryDelay, _scanForSpeakers);
  }

  /// Runs a scan and adds any newly-found speakers to [availableSpeakers]
  /// without touching already-connected sessions - used by the WiFi setup
  /// hand-off and the "Add / rescan speakers" entry point, both of which
  /// must never wipe out a speaker that's already connected.
  Future<void> discoverMoreSpeakers() => _scanForSpeakers();

  Future<bool> _addSession(SpeakerInfo info, {bool isDevPreview = false}) async {
    final session = SpeakerSession(info)..isDevPreview = isDevPreview;
    if (sessions.any((s) => s.id == session.id)) return false;
    sessions = [...sessions, session];
    _startSessionTimers(session);
    notifyListeners();
    await _persistSessions();
    unawaited(refreshStatus(session));
    unawaited(_refreshPresets(session));
    return true;
  }

  void _startSessionTimers(SpeakerSession session) {
    session.pollTimer?.cancel();
    session.pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshStatus(session));

    // Dev-preview sessions point at a FakeSpeakerServer that never opens a
    // real notification WebSocket - there's no physical button to catch a
    // press from, so there's nothing for this to connect to.
    session.presetButtonRelay?.stop();
    if (!session.isDevPreview) {
      session.presetButtonRelay = PresetButtonRelayService(session.speaker.ip)..start();
    }

    session.displayTickTimer?.cancel();
    session.displayTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Freeze the smooth ticker whenever playback isn't actually advancing:
      // `manuallyPaused` is a local flag set synchronously (before any
      // awaited network call) the instant the user taps pause, in sendKey -
      // so it doesn't have to wait for the next poll to take effect.
      // `nowPlaying?.isPlaying` (playStatus == 'PLAY_STATE') catches every
      // other non-playing case, including stopped/buffering states.
      // The 5-second resync in refreshStatus() still exists as a backstop
      // for bounding drift on top of this - it just no longer has anything
      // to correct during an ordinary pause, so the visible "count up then
      // snap back down" sawtooth goes away.
      final actuallyPlaying = !session.manuallyPaused && session.nowPlaying?.isPlaying == true;
      if (session.displayElapsedSeconds != null && actuallyPlaying) {
        session.displayElapsedSeconds = session.displayElapsedSeconds! + 1;
        notifyListeners();
      }
    });
  }

  Future<void> _persistSessions() async {
    final toSave = sessions.where((s) => !s.isDevPreview).map((s) => s.speaker).toList();
    // Whatever this app is about to persist for a device becomes its known
    // name from this point on - see _knownNames' own doc comment. This is
    // the single place that keeps the two in sync, since _persistSessions
    // already runs after every meaningful session change (connect, rename,
    // relocate).
    for (final s in toSave) {
      if (s.deviceId.isNotEmpty) _knownNames[s.deviceId] = s.name;
    }
    await _settingsService.saveSpeakers(toSave);
  }

  Future<void> forgetSpeaker(SpeakerSession session) async {
    session.cancelTimers();
    sessions = sessions.where((s) => s.id != session.id).toList();
    // An explicit forget should forget everything about this device,
    // including any name this app has learned for it - otherwise re-adding
    // it later in the same process would surprisingly "remember" a name the
    // user just told the app to forget.
    _knownNames.remove(session.speaker.deviceId);
    notifyListeners();
    await _persistSessions();
    final fake = _fakeServers.remove(session.id);
    await fake?.stop();
  }

  /// Per-speaker "forget and re-find this one" - e.g. its IP changed and the
  /// cached address stopped responding.
  Future<void> rescanSpeaker(SpeakerSession session) async {
    await forgetSpeaker(session);
    await _scanForSpeakers();
  }

  /// Renames the speaker itself via XmlApiClient.setName - see its own doc
  /// comment for why this is a real device-level rename, not a local-only
  /// override. No-op on a blank/unchanged name (callers - the rename dialog,
  /// the optional connect-time prompt - already treat an empty/skipped
  /// result as "leave it alone", but this guards direct callers too).
  Future<void> renameSpeaker(SpeakerSession session, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == session.speaker.name) return;
    await _withStatus(session, 'Renaming to "$trimmed"...', () async {
      await XmlApiClient.setName(session.speaker.ip, trimmed);
      // refreshStatus's periodic poll never re-fetches /info (its own scope
      // is now-playing/volume/group/presets only) - nothing else would ever
      // pick up a successful rename, so apply it locally right away.
      session.speaker = SpeakerInfo(ip: session.speaker.ip, deviceId: session.speaker.deviceId, name: trimmed);
      session.statusMessage = '';
      await _persistSessions();
      notifyListeners();
    });
  }

  Future<void> addSpeakerByIp(String ip) async {
    statusMessage = 'Checking $ip...';
    notifyListeners();
    final info = await _discovery.probeKnownIp(ip);
    if (info != null) {
      final added = await _addSession(_withKnownName(info));
      statusMessage = added ? '' : 'That speaker is already connected.';
    } else {
      statusMessage = 'Could not reach a SoundTouch speaker at $ip';
    }
    notifyListeners();
  }

  /// Dev escape hatch: appends a fake speaker to [availableSpeakers] so the
  /// new available-speaker/Connect flow (and, once connected, the player
  /// card's layout, including the multi-card layout by tapping this + then
  /// Connect more than once) can be viewed/edited without any reachable
  /// SoundTouch device on the network. Each tap adds a distinct fake
  /// speaker rather than replacing one; connecting one skips persistence
  /// (see connectToSpeaker's isDevPreview check / SpeakerSession.isDevPreview).
  void previewWithoutSpeaker() {
    _devPreviewCounter++;
    final info = SpeakerInfo(
      ip: '127.0.0.$_devPreviewCounter',
      deviceId: 'dev-preview-$_devPreviewCounter',
      name: 'Preview Speaker $_devPreviewCounter',
    );
    _addAvailable(info);
    notifyListeners();
  }

  // ===========================================================================
  // Stereo pairing ("group") - unverified against real hardware, see
  // XmlApiClient's _groupPath doc comment. Every mutation here re-polls
  // getGroup on both member IPs immediately afterward rather than trusting
  // the POST's echoed response, mirroring the Timer(500ms, refreshStatus)
  // re-poll idiom used everywhere else in this file for the same reason:
  // the device's own state is the only thing the UI should ever trust.
  // ===========================================================================

  Future<void> _repollGroup(SpeakerSession session) async {
    try {
      session.group = await XmlApiClient.getGroup(session.speaker.ip);
      session.groupPollEverSucceeded = true;
    } catch (_) {
      // Leave the previous snapshot in place on a transient failure, same
      // as _refreshPresets does for presets.
    }
    notifyListeners();
  }

  Future<void> pairAsStereo({required SpeakerSession left, required SpeakerSession right, String? name}) async {
    final roles = [
      GroupRole(deviceId: left.speaker.deviceId, role: StereoRole.left, ipAddress: left.speaker.ip),
      GroupRole(deviceId: right.speaker.deviceId, role: StereoRole.right, ipAddress: right.speaker.ip),
    ];
    statusMessage = 'Pairing ${left.speaker.name} + ${right.speaker.name}...';
    notifyListeners();
    try {
      await XmlApiClient.addGroup(left.speaker.ip, masterDeviceId: left.speaker.deviceId, roles: roles, name: name);
    } catch (e) {
      statusMessage = 'Error pairing: $e';
      notifyListeners();
    }
    await _repollGroup(left);
    await _repollGroup(right);
  }

  /// Re-pairs with left/right swapped - there's no separate "swap" endpoint
  /// documented, so this just re-issues pairAsStereo with roles flipped.
  Future<void> swapStereoChannels(PlaybackTarget target) async {
    if (!target.isPaired) return;
    await pairAsStereo(left: target.right, right: target.left);
  }

  Future<void> unpairStereo(PlaybackTarget target) async {
    if (!target.isPaired) return;
    try {
      await XmlApiClient.removeGroup(target.commandTarget.speaker.ip);
    } catch (_) {
      // Still re-poll below - if the pair actually dissolved despite the
      // error (or was already gone), the next poll reflects reality either way.
    }
    await _repollGroup(target.left);
    await _repollGroup(target.right);
  }

  // ===========================================================================
  // Multi-room Zone grouping - see ZoneInfo's own doc comment for how this
  // differs from stereo pairing above. Every mutation re-polls getZone on
  // every affected member immediately afterward, same re-poll-don't-trust-
  // the-POST idiom used for stereo pairing. All of these take PlaybackTargets
  // rather than raw SpeakerSessions, and always resolve to .commandTarget -
  // an already stereo-paired duo is one indivisible unit here, coordinated
  // through its own pairing master, never split across two zone roles.
  // ===========================================================================

  Future<void> _repollZone(SpeakerSession session) async {
    try {
      session.zone = await XmlApiClient.getZone(session.speaker.ip);
      session.zonePollEverSucceeded = true;
    } catch (_) {
      // Leave the previous snapshot in place on a transient failure, same
      // as _repollGroup does for stereo pairing.
    }
    notifyListeners();
  }

  /// Creates a new zone (or replaces an existing one [master]/[slaves] were
  /// already part of) with [master]'s commandTarget coordinating playback,
  /// volume, and presets for every slave's commandTarget.
  Future<void> createZone({required PlaybackTarget master, required List<PlaybackTarget> slaves}) async {
    final masterSession = master.commandTarget;
    final slaveSessions = slaves.map((t) => t.commandTarget).toList();
    final members = [
      ZoneMember(deviceId: masterSession.speaker.deviceId, ipAddress: masterSession.speaker.ip),
      ...slaveSessions.map((s) => ZoneMember(deviceId: s.speaker.deviceId, ipAddress: s.speaker.ip)),
    ];
    statusMessage = 'Grouping ${masterSession.speaker.name} + ${slaveSessions.length} speaker(s)...';
    notifyListeners();
    try {
      await XmlApiClient.setZone(masterSession.speaker.ip, masterDeviceId: masterSession.speaker.deviceId, members: members);
    } catch (e) {
      statusMessage = 'Error grouping: $e';
      notifyListeners();
    }
    await _repollZone(masterSession);
    for (final s in slaveSessions) {
      await _repollZone(s);
    }
  }

  /// Adds one more target to an EXISTING zone [master] is already the master
  /// of.
  Future<void> addToZone({required PlaybackTarget master, required PlaybackTarget newSlave}) async {
    final masterSession = master.commandTarget;
    final slaveSession = newSlave.commandTarget;
    try {
      await XmlApiClient.addZoneSlave(
        masterSession.speaker.ip,
        masterDeviceId: masterSession.speaker.deviceId,
        newSlaves: [ZoneMember(deviceId: slaveSession.speaker.deviceId, ipAddress: slaveSession.speaker.ip)],
      );
    } catch (e) {
      statusMessage = 'Error adding to group: $e';
      notifyListeners();
    }
    await _repollZone(masterSession);
    await _repollZone(slaveSession);
  }

  /// Removes just [slave] from its zone, leaving the rest of the zone (and
  /// its master) intact.
  Future<void> removeFromZone({required PlaybackTarget master, required PlaybackTarget slave}) async {
    final masterSession = master.commandTarget;
    final slaveSession = slave.commandTarget;
    try {
      await XmlApiClient.removeZoneSlave(
        masterSession.speaker.ip,
        masterDeviceId: masterSession.speaker.deviceId,
        slaves: [ZoneMember(deviceId: slaveSession.speaker.deviceId, ipAddress: slaveSession.speaker.ip)],
      );
    } catch (e) {
      statusMessage = 'Error removing from group: $e';
      notifyListeners();
    }
    await _repollZone(masterSession);
    await _repollZone(slaveSession);
  }

  /// Dissolves the whole zone [anyMember] currently belongs to - removes
  /// every OTHER member as a slave from the master, which (per
  /// XmlApiClient.removeZoneSlave's own doc comment - no separate "remove
  /// entire zone" endpoint is documented) is the closest equivalent to a
  /// full "ungroup". No-op if [anyMember]'s commandTarget isn't zoned.
  Future<void> dissolveZone(PlaybackTarget anyMember) async {
    final session = anyMember.commandTarget;
    final zone = session.zone;
    if (zone == null) return;
    final masterSession = sessionById(zone.masterDeviceId) ?? session;
    final otherMembers = zone.members.where((m) => m.deviceId != zone.masterDeviceId).toList();
    if (otherMembers.isEmpty) return;
    try {
      await XmlApiClient.removeZoneSlave(masterSession.speaker.ip, masterDeviceId: masterSession.speaker.deviceId, slaves: otherMembers);
    } catch (e) {
      statusMessage = 'Error ungrouping: $e';
      notifyListeners();
    }
    await _repollZone(masterSession);
    for (final m in otherMembers) {
      final s = sessionById(m.deviceId);
      if (s != null) await _repollZone(s);
    }
  }

  // ===========================================================================
  // Per-speaker status polling
  // ===========================================================================

  // ~2 minutes at the 5s poll cadence - long past any transient WiFi blip,
  // but still far short of "the user gives up and force-closes the app."
  // Before this existed, a session that went unreachable mid-session (a
  // factory reset, unplugged speaker, etc.) just sat in `sessions` forever
  // looking like a normal connected card - _scanForSpeakers' own retry loop
  // only ever runs right after launch or an explicit user action, so
  // nothing was left to notice the speaker was gone until the app was
  // closed and reopened, which re-runs _findSpeakers from scratch and
  // correctly leaves it out. Confirmed as a real complaint, 2026-07-25.
  static const _autoRescanUnreachableStreak = 24;

  // Skips this poll tick entirely while any _withStatus-guarded command is
  // mid-flight - added 2026-07-28 after a field-confirmed bug: this poller
  // (running unconditionally every 5s via pollTimer) could otherwise land
  // its own GET /now_playing, /volume, /getGroup, /getZone, /presets calls on
  // the very same speaker while a multi-step command (e.g. a play/pause/
  // volume change still awaiting its HTTP response) was mid-flight - this
  // firmware is already known elsewhere in this file to mishandle
  // overlapping local-API requests (see SoapClient's own docs on
  // SetAVTransportURI/Play being accepted with 200 but not applied).
  //
  // This was originally discovered via the app's own former "hold a preset
  // button to save" feature (a synthetic press-wait-release sequence against
  // /key, standing in for a real physical hold) - the poller's concurrent
  // traffic landing mid-sequence could corrupt the hold-duration the
  // firmware measures, silently no-op'ing the save on the device's real
  // (physical-button-facing) preset table even though the app's own
  // immediate read-back still looked like success. That feature has since
  // been removed entirely (confirmed via real-hardware field testing,
  // 2026-08-15: even with this poll-skip fix in place, a preset saved
  // through the app's synthetic hold was STILL never recallable from the
  // speaker's own physical button, only from within the app - a genuine
  // physical hold, done by hand, worked reliably both ways. This means the
  // network /key API's "hold" was never actually reaching the same
  // persistent store a real hardware hold does, regardless of timing - not
  // something fixable by racing the poller better.) - but this poll-skip
  // guard itself stays, since the same firmware concurrency issue applies
  // to every other multi-step command here, not just the removed one.
  Future<void> refreshStatus(SpeakerSession session) async {
    if (session.commandInFlight) return;
    final ip = session.speaker.ip;
    try {
      final np = await XmlApiClient.getNowPlaying(ip);
      final vol = await XmlApiClient.getVolumeStatus(ip);
      session.nowPlaying = np;
      // This poll's data is now authoritative for isPlaying - the optimistic
      // bridge flag has done its job (covering the gap between the tap and
      // this poll landing) and must not linger past it, or a later play
      // started through a path other than sendKey('PLAY') (a preset,
      // playlist track, custom URL, etc.) would stay frozen indefinitely.
      session.manuallyPaused = false;
      session.speakerReachable = true;
      session.unreachableStreak = 0;
      if (np.isPlaying) session.displayConfirmedPlaying = true;
      // Resync the smooth display ticker to the real polled value every
      // time - this is what keeps interpolation drift bounded to at most
      // one poll interval, and immediately reflects a track change (new
      // elapsed=0) rather than waiting for the local ticker to catch up.
      // Gated on displayConfirmedPlaying so a rising elapsed count reported
      // by the speaker WHILE STILL BUFFERING never reaches the display.
      if (session.displayConfirmedPlaying) {
        session.displayElapsedSeconds = np.elapsedSeconds;
      }
      if (!session.isDraggingVolume) {
        session.volumeStatus = vol;
        session.displayVolume = vol.actual;
      }
    } catch (_) {
      session.speakerReachable = false;
      session.unreachableStreak++;
      // Drop it and immediately kick _scanForSpeakers' retry/relocate loop
      // back into action - rescanSpeaker (forgetSpeaker + a fresh scan) is
      // the exact same one-tap action Settings already exposes for this,
      // just fired automatically instead of waiting for the user to notice
      // and tap it themselves. If the speaker was only moved/renamed/back
      // on a flaky router, the scan finds it again and lists it in
      // availableSpeakers for a single "Connect" tap - no full WiFi-setup
      // redo needed unless it was genuinely factory-reset. `return` here
      // skips the rest of this poll (group/presets/notifyListeners below)
      // since forgetSpeaker already cancels this exact session's timers
      // (including the pollTimer currently running this callback) and
      // calls notifyListeners() itself.
      if (session.unreachableStreak == _autoRescanUnreachableStreak) {
        unawaited(rescanSpeaker(session));
        return;
      }
    }
    // Independent try/catch: stereo-pairing support is unconfirmed on any
    // given model/firmware, and a failure here must not affect the
    // now-playing/volume poll above or vice versa.
    try {
      session.group = await XmlApiClient.getGroup(ip);
      session.groupPollEverSucceeded = true;
    } catch (_) {
      session.group = null;
    }
    // Independent from the stereo-group poll above too - a speaker could in
    // principle support one Bose feature but not the other (or neither), and
    // one failing must never block the other from ever being tried.
    try {
      session.zone = await XmlApiClient.getZone(ip);
      session.zonePollEverSucceeded = true;
    } catch (_) {
      session.zone = null;
    }
    // Also independent: previously presets were only fetched once, right
    // when a session first connects (see _addSession), plus right after
    // THIS APP saves one itself - a preset saved via the speaker's own
    // PHYSICAL hold-to-save (which the app has no direct signal for) never
    // showed up in the app until the next reconnect. Piggybacking on the
    // same 5s cadence as everything else above picks it up automatically,
    // the same way nowPlaying/volume/group already do.
    try {
      session.presets = await XmlApiClient.getPresets(ip);
    } catch (_) {
      // Leave the previous preset snapshot in place on a transient failure,
      // same as _refreshPresets does when called from elsewhere.
    }
    notifyListeners();
  }

  Future<void> _refreshPresets(SpeakerSession session) async {
    try {
      session.presets = await XmlApiClient.getPresets(session.speaker.ip);
      notifyListeners();
    } catch (_) {
      // Leave the previous preset snapshot in place on transient failure.
    }
  }

  /// Drops (rather than queues) a second call for the same session while a
  /// prior one is still in flight - see SpeakerSession.commandInFlight's doc
  /// comment for why overlapping AVTransport commands are worth avoiding
  /// outright, not just racing and hoping. A quick double-tap now silently
  /// no-ops on the second tap instead of firing two overlapping SOAP calls.
  Future<void> _withStatus(SpeakerSession session, String message, Future<void> Function() action) async {
    if (session.commandInFlight) return;
    session.commandInFlight = true;
    session.statusMessage = message;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      // BlankStreamUrlException gets its own friendly wording (no "Error: "
      // prefix, no raw exception dump) - see its doc comment in
      // soap_client.dart. Every other exception keeps the existing
      // generic "Error: $e" surface.
      session.statusMessage = e is BlankStreamUrlException ? BlankStreamUrlException.message : 'Error: $e';
      notifyListeners();
    } finally {
      session.commandInFlight = false;
    }
  }

  // ===========================================================================
  // Per-speaker transport / volume / preset actions
  // ===========================================================================

  Future<void> sendKey(SpeakerSession session, String key) async {
    final ip = session.speaker.ip;
    // Set synchronously, BEFORE the awaited network round trip below, so the
    // display ticker freezes at the moment of the tap - see manuallyPaused's
    // doc comment for why this can't just wait on nowPlaying to catch up.
    if (key == 'PAUSE') {
      session.manuallyPaused = true;
      notifyListeners();
    } else if (key == 'PLAY') {
      session.manuallyPaused = false;
      notifyListeners();
    }
    await _withStatus(session, '', () async {
      await XmlApiClient.sendKey(ip, key);
      Timer(const Duration(milliseconds: 500), () => refreshStatus(session));
    });
  }

  Future<void> toggleAuxSource(SpeakerSession session) async {
    final ip = session.speaker.ip;
    final target = session.auxToggleTarget;
    await _withStatus(session, 'Switching to $target...', () async {
      await XmlApiClient.selectSource(ip, target);
      Timer(const Duration(milliseconds: 800), () => refreshStatus(session));
    });
  }

  /// Continuous drag feedback: updates the visible number immediately, but
  /// debounces the actual network call 120ms so a fast drag doesn't flood
  /// the speaker with volume-set requests.
  /// Changed 2026-07-23 from a pure debounce (only send once 120ms passes
  /// with NO new drag events) to a throttle (send at most every 120ms, but
  /// send WHILE still dragging too). A debounce here meant a single smooth,
  /// continuous drag gesture - which is how a slider is normally used, to
  /// hear the volume change live as a guide for where to stop - never
  /// actually reached the speaker until the user paused or released,
  /// because Slider's onChanged fires far more often than every 120ms while
  /// actively dragging, so the debounce timer kept getting cancelled and
  /// reset by the very next drag event before it could ever fire. The
  /// speaker's real, audible volume only updated at the very end - exactly
  /// the "matagal mag-reflect ang sound" lag reported live. setVolume sets
  /// an ABSOLUTE level each call, so sending more often than strictly
  /// necessary is harmless (no risk of double-applying a delta) - the only
  /// real cost is call frequency, and 120ms (up to ~8/s) is well within what
  /// a local-network SOAP call can handle.
  void onVolumeInput(SpeakerSession session, int level) {
    session.isDraggingVolume = true;
    session.displayVolume = level;
    notifyListeners();
    final ip = session.speaker.ip;
    final now = DateTime.now();
    final last = session.lastVolumeSentAt;
    if (last == null || now.difference(last) >= const Duration(milliseconds: 120)) {
      session.volumeDebounceTimer?.cancel();
      session.lastVolumeSentAt = now;
      XmlApiClient.setVolume(ip, level);
    } else {
      // Still inside this throttle window - schedule a trailing send so the
      // FINAL value of a drag that stops mid-window still reaches the
      // speaker, instead of only ever sending on a throttle boundary.
      session.volumeDebounceTimer?.cancel();
      session.volumeDebounceTimer = Timer(const Duration(milliseconds: 120), () {
        session.lastVolumeSentAt = DateTime.now();
        XmlApiClient.setVolume(ip, level);
      });
    }
  }

  Future<void> onVolumeChange(SpeakerSession session, int level) async {
    session.volumeDebounceTimer?.cancel();
    final ip = session.speaker.ip;
    session.displayVolume = level;
    notifyListeners();
    await _withStatus(session, 'Setting volume to $level...', () async {
      await XmlApiClient.setVolume(ip, level);
      Timer(const Duration(milliseconds: 500), () => refreshStatus(session));
    });
    session.isDraggingVolume = false;
    notifyListeners();
  }

  Future<void> volStep(SpeakerSession session, int delta) async {
    final newVal = (session.displayVolume + delta).clamp(0, 100);
    await onVolumeChange(session, newVal);
  }

  /// L/R balance for a stereo pair - always commands [PlaybackTarget.left]
  /// specifically (confirmed working convention: targetBalance only takes
  /// effect sent to the LEFT member, regardless of which side is master).
  /// Same continuous-drag/debounce shape as onVolumeInput.
  void onBalanceInput(PlaybackTarget target, int value) {
    if (!target.isPaired) return;
    final left = target.left;
    left.balanceValue = value;
    notifyListeners();
    left.balanceDebounceTimer?.cancel();
    final ip = left.speaker.ip;
    left.balanceDebounceTimer = Timer(const Duration(milliseconds: 120), () {
      XmlApiClient.setBalance(ip, value);
    });
  }

  Future<void> onBalanceChange(PlaybackTarget target, int value) async {
    if (!target.isPaired) return;
    final left = target.left;
    left.balanceDebounceTimer?.cancel();
    left.balanceValue = value;
    notifyListeners();
    await _withStatus(left, 'Setting balance...', () async {
      await XmlApiClient.setBalance(left.speaker.ip, value);
    });
  }

  Future<void> playPreset(SpeakerSession session, String num) async {
    final ip = session.speaker.ip;
    final url = session.presets[num]?.contentItemLocation;
    // .trim() here too (not just .isEmpty) - defense in depth alongside the
    // normalization already done in PresetSlot.listFromXmlString, so a
    // whitespace-only device-reported location can never reach
    // SoapClient.play via this call site either way.
    if (url == null || url.trim().isEmpty) {
      session.statusMessage = 'Preset $num is empty.';
      notifyListeners();
      return;
    }
    await _withStatus(session, 'Playing preset $num...', () async {
      await SoapClient.play(ip, url);
      Timer(const Duration(milliseconds: 1500), () => refreshStatus(session));
    });
  }

  Future<void> playCustomUrl(SpeakerSession session, String url, {String? title, Duration? duration}) async {
    final ip = session.speaker.ip;
    // Otherwise the display ticker keeps counting up from the PREVIOUS
    // track's elapsed value for up to 5s, until the next poll resyncs it -
    // showing a stale/nonsensical progress readout for a new track.
    session.displayElapsedSeconds = null;
    session.displayConfirmedPlaying = false;
    // This is a new play command, so any leftover optimistic "manually
    // paused" freeze from a previous transport-row Pause tap no longer
    // applies - don't let it wrongly freeze the ticker for this new track
    // until the next poll happens to clear it.
    session.manuallyPaused = false;
    // Deliberately a plain, title-less message - the player card's own now-
    // playing line already shows the real resolved title persistently (see
    // SpeakerController.currentPlayingTitle), so baking the same title into
    // this transient status line too just left a stale, duplicate-looking
    // "Loading X..." sitting there indefinitely after a successful play
    // (this message is never cleared back to '' on success - see
    // _withStatus - so it used to be the closest thing to a permanent title
    // display before currentPlayingTitle existed).
    await _withStatus(session, 'Loading...', () async {
      await SoapClient.play(ip, url, title: title, duration: duration);
      Timer(const Duration(milliseconds: 1500), () => refreshStatus(session));
    });
  }

  // ===========================================================================
  // Global search (radio/YouTube) - shared results list, played onto an
  // explicit target speaker.
  // ===========================================================================

  Future<void> searchRadio(String query) async {
    if (query.isEmpty) return;
    lastRadioQuery = query;
    radioLoading = true;
    radioError = null;
    notifyListeners();
    try {
      radioResults = await TuneInApiClient.search(query);
      _prefetchRadioUrls(radioResults);
    } catch (e) {
      // Deliberately leave radioResults as whatever they were before (this
      // session's last successful search, if any) - a dropped connection
      // shouldn't blank out results that are still perfectly playable, just
      // not re-searchable right now.
      radioError = '$e';
    }
    radioLoading = false;
    notifyListeners();
  }

  /// stationId -> resolved real stream URL (see TuneInApiClient.resolveStreamUrl),
  /// plus when it was cached - resolving is a real network round trip (a
  /// TuneIn API call, occasionally a second hop through a .pls/.m3u
  /// playlist), so every lookup this session reuses a cached result rather
  /// than re-resolving from scratch. TTL mirrors this project's old PC-side
  /// proxy cache (3 hours) - long enough that repeat taps/prefetches almost
  /// never re-hit the network, short enough that a station's origin
  /// changing CDN endpoints eventually self-heals without an app restart.
  final Map<String, ({String url, DateTime at})> _radioUrlCache = {};
  static const _radioUrlCacheTtl = Duration(hours: 3);

  /// Station ids confirmed (via a real resolve attempt throwing
  /// UnplayableStationException) to be https-only - a permanent, hardware-
  /// level incompatibility, not a transient failure. [visibleRadioResults]
  /// filters these out so the search list never shows something that's
  /// confirmed to just silently fail when tapped. Never removed once added -
  /// unlike _radioUrlCache's TTL, there's no future network state in which an
  /// already-confirmed https:// stream becomes plain http overnight.
  final Set<String> unplayableStationIds = {};

  /// Defaults to a real TuneIn API call; tests override this to a fast,
  /// deterministic fake instead of hitting the real network for made-up
  /// station ids - same seam pattern as PresetButtonRelayService's
  /// channelFactory.
  @visibleForTesting
  Future<String?> Function(String stationId) resolveRadioUrl = TuneInApiClient.resolveStreamUrl;

  Future<String?> _resolveRadioUrl(String stationId) async {
    final cached = _radioUrlCache[stationId];
    if (cached != null && DateTime.now().difference(cached.at) < _radioUrlCacheTtl) {
      return cached.url;
    }
    String? url;
    try {
      url = await resolveRadioUrl(stationId);
    } on UnplayableStationException {
      unplayableStationIds.add(stationId);
      notifyListeners();
      return null;
    }
    // A failed resolve is NOT cached (unlike a success) - it's likely
    // transient (network hiccup), so the next attempt (a retry tap, the
    // next prefetch pass) should hit the network again rather than being
    // stuck on a remembered failure for the rest of the TTL window.
    if (url != null) _radioUrlCache[stationId] = (url: url, at: DateTime.now());
    return url;
  }

  /// The current search results with any confirmed-unplayable (https-only)
  /// stations filtered out - this is what the UI should always show/browse,
  /// so a station that's confirmed to just fail silently when tapped never
  /// stays visible. A result not yet resolved gets the benefit of the doubt
  /// and stays visible until _prefetchRadioUrls (or a direct tap) proves
  /// otherwise.
  List<RadioResult> get visibleRadioResults =>
      radioResults.where((r) => !unplayableStationIds.contains(r.id)).toList();

  /// True while [radioResults] still reflects the untouched startup default
  /// search rather than an explicit user search - lets the TuneIn tab label
  /// its results grid "RECOMMENDED STATIONS" instead of implying the user
  /// had to search to get them.
  bool get radioResultsAreDefault => lastRadioQuery == _defaultRadioQuery;

  /// Resolves every current search result's stream URL in the background
  /// right after a search completes, so tapping any of them plays almost
  /// instantly AND so unplayable (https-only) ones get filtered out of
  /// [visibleRadioResults] promptly rather than lingering visible until
  /// someone happens to tap one. Best-effort and fire-and-forget: a failed
  /// or slow resolve just means the eventual real play request falls back to
  /// the normal (slower) cold-resolve path, never blocks or affects
  /// search/browsing itself. Unbounded (not just the first few) since this
  /// now also drives visibility, not just tap-to-play latency - TuneIn
  /// search result counts are small enough that resolving all of them
  /// concurrently in the background is not a concern.
  void _prefetchRadioUrls(List<RadioResult> results) {
    for (final r in results) {
      unawaited(_resolveRadioUrl(r.id));
    }
  }

  Future<void> playRadioResult(SpeakerSession session, RadioResult r) async {
    final url = await _resolveRadioUrl(r.id);
    if (url == null) {
      setStatusMessage('Could not play "${r.name}" - this station is not available right now.');
      return;
    }
    unawaited(_addToRecentlyPlayed(r));
    await _tryRegisterPresetableStream(session, url, r.name);
    await playCustomUrl(session, url);
  }

  /// Best-effort wrapper around XmlApiClient.registerPresetableStream - see
  /// its own doc comment for what this experiment is trying to fix (physical
  /// hold-to-save rejecting radio stations) and why it's unverified. Any
  /// failure here is swallowed and never surfaced to the user - this is
  /// purely a bonus attempt on top of already-working playback, awaited
  /// BEFORE the real play call below so it can never race or override it.
  Future<void> _tryRegisterPresetableStream(SpeakerSession session, String url, String name) async {
    try {
      await XmlApiClient.registerPresetableStream(session.speaker.ip, url, name);
    } catch (_) {
      // Best-effort - see doc comment above.
    }
  }

  bool isRadioPlaying(SpeakerSession session, RadioResult r) {
    return _radioUrlCache[r.id]?.url == session.nowPlaying?.location;
  }

  /// Whether the CURRENTLY playing thing on [session] is a known TuneIn
  /// search result - drives the player card's source-indicator label.
  bool isPlayingRadio(SpeakerSession session) {
    final loc = session.nowPlaying?.location;
    if (loc == null) return false;
    return radioResults.any((r) => _radioUrlCache[r.id]?.url == loc);
  }

  /// The real, human-readable title of whatever's CURRENTLY playing on
  /// [session], when knowable - for both the player card's now-playing line
  /// and the lock-screen notification (see SoundTouchAudioHandler). Null
  /// when nothing playing matches a known search result (AUX, standby, a
  /// plain non-search preset, etc) - callers should fall back to
  /// NowPlaying.displayText in that case.
  ///
  /// Deliberately NOT read from session.nowPlaying?.track/stationName - the
  /// device is intentionally never SENT a title for anything played from
  /// search results (sending DIDL-Lite title metadata marks the ContentItem
  /// isPresetable="false" on real hardware, which would silently break
  /// "hold to save as preset" - confirmed against real hardware,
  /// 2026-07-19). So the device's own now_playing response never carries a
  /// usable title for these sources, by design - this recovers a real title
  /// client-side instead, by matching the CURRENTLY playing location back
  /// against radioResults.
  String? currentPlayingTitle(SpeakerSession session) {
    final loc = session.nowPlaying?.location;
    if (loc == null) return null;
    for (final r in radioResults) {
      if (_radioUrlCache[r.id]?.url == loc) return r.name;
    }
    return null;
  }

  Future<void> setOpenRemoteByDefault(bool value) async {
    settings = settings.copyWith(openRemoteByDefault: value);
    await _settingsService.saveSettings(settings);
    notifyListeners();
  }

  /// Same lightweight shape as [setOpenRemoteByDefault] - called whenever
  /// RemoteScreen's own Design 1/Design 2 chips are tapped, so the choice
  /// survives closing the screen (and the app) and is what
  /// HomeScreen._maybeAutoOpenRemote lands on next time, independently of
  /// whichever design was showing the very first time either feature was
  /// ever used.
  Future<void> setLastRemoteDesignIndex(int index) async {
    settings = settings.copyWith(lastRemoteDesignIndex: index);
    await _settingsService.saveSettings(settings);
    notifyListeners();
  }

  /// Previous/Next for the plain transport row ([direction] -1/+1). Two
  /// cases, in priority order:
  /// 1. What's CURRENTLY playing matches an entry in the live radioResults
  ///    list (a plain one-shot tap on a search result) - step to the
  ///    adjacent entry in that list and play it, wrapping unconditionally
  ///    (first<->last). Dart's int % is already non-negative for a positive
  ///    divisor, so (index + direction) % length wraps both directions with
  ///    no extra branching.
  /// 2. Otherwise - fall back to the generic PREV_TRACK/NEXT_TRACK device
  ///    key (AUX, a non-search preset, nothing playing, etc).
  Future<void> transportSkip(SpeakerSession session, int direction) async {
    final loc = session.nowPlaying?.location;
    if (loc != null) {
      final visible = visibleRadioResults;
      final radioIdx = visible.indexWhere((r) => _radioUrlCache[r.id]?.url == loc);
      if (radioIdx != -1) {
        final wrapped = (radioIdx + direction) % visible.length;
        await playRadioResult(session, visible[wrapped]);
        return;
      }
    }

    await sendKey(session, direction > 0 ? 'NEXT_TRACK' : 'PREV_TRACK');
  }
}
