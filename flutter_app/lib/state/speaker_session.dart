import 'dart:async';

import '../models/group_info.dart';
import '../models/now_playing.dart';
import '../models/preset_slot.dart';
import '../models/speaker_info.dart';
import '../models/volume_status.dart';
import '../models/zone_info.dart';
import '../services/preset_button_relay_service.dart';

/// Per-connected-speaker playback state - one instance per entry in
/// `SpeakerController.sessions`. Plain mutable data, not its own
/// ChangeNotifier: SpeakerController stays the single ChangeNotifier for the
/// whole app (see its own doc comment) - this just gives each connected
/// speaker its own copy of what used to be SpeakerController's single set of
/// playback fields, back when only one speaker could ever be connected.
class SpeakerSession {
  SpeakerSession(this.speaker);

  SpeakerInfo speaker;

  /// Stable key for lookups/dedup - every real device populates deviceId via
  /// getInfo; dev-preview sessions set a non-empty fake one too.
  String get id => speaker.deviceId.isNotEmpty ? speaker.deviceId : speaker.ip;

  /// True for fake speakers added via SpeakerController.previewWithoutSpeaker
  /// - excluded from the persisted speaker cache, since they aren't real.
  bool isDevPreview = false;

  NowPlaying? nowPlaying;
  VolumeStatus? volumeStatus;
  Map<String, PresetSlot> presets = {};

  bool isDraggingVolume = false;
  int displayVolume = 30;

  String statusMessage = '';
  bool speakerReachable = false;

  /// True while a transport-mutating command (anything that sends
  /// SetAVTransportURI/Play or a /key press+release to the real speaker) is
  /// awaiting its HTTP response for THIS session. A second command firing
  /// while the first is still in flight would race it on the wire - a real
  /// SoundTouch 10's AVTransport service has been directly observed (via
  /// manual curl testing, 2026-07-2x) accepting two overlapping
  /// SetAVTransportURI/Play sequences with HTTP 200 each, then never
  /// actually applying either one (stuck reporting stale state indefinitely)
  /// - a consumer-UPnP-firmware concurrency issue, not something fixable by
  /// retrying harder. Checked-and-set at the top of every command method
  /// that talks to AVTransport, cleared in a finally - see
  /// SpeakerController._withStatus and ._commandActiveTrack.
  bool commandInFlight = false;

  /// Consecutive failed polls, reset to 0 on any success. Used to require 2
  /// consecutive misses (matching the existing terminalStreak pattern for
  /// "did the track end") before a stereo-paired card falls back to split,
  /// rather than flickering the whole card layout on one transient Wi-Fi hiccup.
  int unreachableStreak = 0;

  /// Last-polled stereo-pairing snapshot (see SpeakerController.refreshStatus)
  /// - null means "not currently paired" or "couldn't tell", indistinguishably.
  GroupInfo? group;

  /// True once a getGroup() poll for this session has completed without
  /// throwing at least once (regardless of whether it returned an active
  /// pairing) - the capability gate for offering "Pair as Stereo" on this
  /// speaker, since a dev-preview session's fake IP never succeeds here.
  bool groupPollEverSucceeded = false;

  /// Last-polled multi-room Zone snapshot (see SpeakerController.refreshStatus)
  /// - null means "not currently zoned" or "couldn't tell", indistinguishably.
  /// See ZoneInfo's own doc comment for how this differs from [group] above.
  ZoneInfo? zone;

  /// Same capability-gate role as [groupPollEverSucceeded], for the Zone
  /// grouping UI instead of stereo pairing.
  bool zonePollEverSucceeded = false;

  /// Optimistic bridge flag for the plain transport-row Pause/Play buttons.
  /// Set/cleared SYNCHRONOUSLY the instant the button is tapped, before the awaited
  /// XmlApiClient.sendKey round trip even starts, so the display ticker
  /// freezes at the moment of the tap rather than only once nowPlaying's
  /// stale PLAY_STATE finally gets overwritten by the next poll (which was
  /// otherwise a window of over-ticking followed by a backward snap - the
  /// same sawtooth this whole ticker-gating scheme exists to avoid). Only
  /// needs to bridge until the next real poll lands - refreshStatus() clears
  /// it unconditionally as soon as fresh data arrives, since nowPlaying?.isPlaying
  /// alone is authoritative from that point on.
  bool manuallyPaused = false;

  /// A once-per-second, UI-only estimate of elapsed playback time,
  /// interpolated between the real 5-second now_playing polls so the
  /// on-screen timer/progress bar ticks smoothly instead of visibly jumping
  /// by ~5 every poll. Resynced to the real polled value on every
  /// refreshStatus() tick, so drift never accumulates for more than one poll
  /// interval. The actual auto-advance logic keeps using the real polled
  /// NowPlaying.elapsedSeconds, never this - this field is display-only.
  int? displayElapsedSeconds;

  /// True once a poll has actually observed PLAY_STATE for the current
  /// track - false during the initial buffering/loading window right after
  /// a track is commanded. The speaker itself appears to report a rising
  /// elapsed count WHILE STILL BUFFERING (observed: counts up during load,
  /// then resets back down once real audio playback actually begins) - so
  /// showing/ticking the display before this is confirmed produces a
  /// confusing "counts up then jumps back to 1" readout that isn't wrong
  /// data, just the wrong phase to be showing a track-position clock for.
  bool displayConfirmedPlaying = false;

  /// L/R balance when this session is the LEFT member of a stereo pair (-50
  /// full left .. 0 center .. +50 full right) - see XmlApiClient.setBalance's
  /// doc comment for why this is purely local UI state, not polled from the
  /// device. Resets to center on app restart.
  int balanceValue = 0;

  Timer? pollTimer;
  Timer? displayTickTimer;
  Timer? volumeDebounceTimer;
  Timer? balanceDebounceTimer;

  /// When the last real setVolume call actually went out to the speaker -
  /// see SpeakerController.onVolumeInput's own doc comment for why this
  /// drives a throttle rather than a pure debounce.
  DateTime? lastVolumeSentAt;

  /// Catches a PHYSICAL preset-button press on this session's own speaker
  /// via its notification WebSocket, independently of any PC-side backend -
  /// see PresetButtonRelayService's own doc comment for why this needs to
  /// run from something on the SAME LAN as the speaker (the app itself,
  /// here) rather than the search/stream server. Null for a dev-preview
  /// session (see SpeakerController._startSessionTimers).
  PresetButtonRelayService? presetButtonRelay;

  void cancelTimers() {
    pollTimer?.cancel();
    displayTickTimer?.cancel();
    volumeDebounceTimer?.cancel();
    balanceDebounceTimer?.cancel();
    presetButtonRelay?.stop();
  }

  String get auxToggleTarget => nowPlaying?.source == 'BLUETOOTH' ? 'AUX' : 'BLUETOOTH';

  bool isPresetPlaying(String num) {
    final loc = presets[num]?.contentItemLocation;
    if (loc == null || loc.isEmpty) return false;
    return loc == nowPlaying?.location;
  }

  int? get displayTrueTotalSeconds => nowPlaying?.totalSeconds;

  /// UI-facing "2:59 / 3:00" (or just "2:59" if duration's unknown) built
  /// from the smooth once-per-second ticker, not the raw 5-second-stale
  /// NowPlaying.elapsedSeconds - use this (not NowPlaying.progressText) for
  /// anything shown on screen.
  String? get displayProgressText {
    final elapsed = displayElapsedSeconds;
    if (elapsed == null) return null;
    final total = displayTrueTotalSeconds;
    if (total == null || total <= 0) return NowPlaying.formatSeconds(elapsed);
    return '${NowPlaying.formatSeconds(elapsed)} / ${NowPlaying.formatSeconds(total)}';
  }

  double? get displayProgressFraction {
    final elapsed = displayElapsedSeconds;
    final total = displayTrueTotalSeconds;
    if (elapsed == null || total == null || total <= 0) return null;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}
