import 'package:audio_service/audio_service.dart';

import '../state/speaker_controller.dart';

/// Wires this app's existing remote-speaker control (SpeakerController) into
/// audio_service's BaseAudioHandler - NOT to play audio locally through the
/// phone (this app never decodes/plays audio itself; the physical Bose
/// speaker does that over UPnP), but purely for the Android foreground
/// service + lock-screen/notification media player that audio_service
/// provides as a side effect of registering a handler. BaseAudioHandler's
/// play()/pause()/skip callbacks default to empty no-ops specifically so
/// they can be overridden with arbitrary custom work instead of local
/// playback - here, that work is an existing SOAP/HTTP call to the speaker.
///
/// The real point of all this: audio_service keeps THIS APP'S SINGLE Flutter
/// engine (not a separate isolate) alive inside a real Android foreground
/// service. Everything already running in that engine - each SpeakerSession's
/// 5s poll timer and its PresetButtonRelayService's WebSocket connection to
/// the speaker's notification socket - rides along for free once this is
/// wired up, surviving the user swiping the app away or the screen staying
/// locked for a long time, which would otherwise eventually get a plain
/// closed Flutter app's background execution killed by Android (Doze/App
/// Standby). No changes to PresetButtonRelayService itself were needed.
class SoundTouchAudioHandler extends BaseAudioHandler {
  SpeakerController? _controller;
  SpeakerSession? _activeSession;

  /// Guards the one-time forced foreground promotion in [_syncFromController]
  /// - see its own comment for why this exists. Only ever needs to fire once
  /// per process: androidStopForegroundOnPause: false (main.dart) means that
  /// once the underlying Android service is promoted to the foreground, it
  /// never demotes itself again for the rest of the process's life, so
  /// re-pulsing on later session churn (e.g. reconnecting after a forget)
  /// would be redundant, not incorrect - a one-time flag is simplest.
  bool _forcedInitialForegroundPromotion = false;

  /// Called once, after both this handler and the (single, app-wide)
  /// SpeakerController exist - see main.dart. Keeps listening for as long as
  /// the app runs; there's no matching "detach" because this handler and the
  /// controller share the same lifetime (both live for the whole process).
  void attach(SpeakerController controller) {
    _controller = controller;
    controller.addListener(_syncFromController);
    _syncFromController();
  }

  /// Which session the lock-screen notification reflects, when more than one
  /// speaker is connected. There's no existing "primary speaker" concept
  /// elsewhere in this app to defer to - the first non-dev-preview session is
  /// the simplest non-arbitrary choice, matching the common case of one
  /// paired speaker.
  SpeakerSession? _pickSession(SpeakerController controller) {
    for (final s in controller.sessions) {
      if (!s.isDevPreview) return s;
    }
    return null;
  }

  void _syncFromController() {
    final controller = _controller;
    if (controller == null) return;
    final session = _pickSession(controller);
    _activeSession = session;

    if (session == null) {
      mediaItem.add(null);
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        controls: const [],
      ));
      // Still needs the same forced foreground-promotion pulse as the real-
      // speaker path below (see that branch's own doc comment for the full
      // "rising edge only" reasoning) - "Stream on Your Phone" plays real
      // audio through just_audio entirely outside this handler (it's a local
      // AudioPlayer, not a remote-speaker relay - see
      // SpeakerController.playOnPhone's doc comment), but that playback
      // still runs on this same process/engine, so it needs the exact same
      // protection from Doze/App Standby/OEM background kills whenever no
      // real speaker session exists to have triggered it another way.
      if (controller.phoneStreamingEnabled && !_forcedInitialForegroundPromotion) {
        _forcedInitialForegroundPromotion = true;
        playbackState.add(playbackState.value.copyWith(playing: true, processingState: AudioProcessingState.ready));
        playbackState.add(playbackState.value.copyWith(playing: false, processingState: AudioProcessingState.idle));
      }
      return;
    }

    // audio_service's underlying Android service only calls its own
    // startForeground() on the RISING EDGE of its internal `playing` flag
    // (com.ryanheise.audioservice.AudioService.setState: `if (!wasPlaying &&
    // playing) enterPlayingState()`) - never unconditionally at startup or
    // on session-attach. Without this pulse, a speaker that's connected but
    // never actually played from inside this app (very plausible -
    // PresetButtonRelayService's whole purpose is catching a PHYSICAL preset
    // press, which often happens while nothing is already playing) would
    // never fire that edge, so the process would never actually become a
    // protected foreground service despite the manifest declaring one -
    // leaving every SpeakerSession's 5s poll timer and
    // PresetButtonRelayService's WebSocket exposed to Doze/App Standby/OEM
    // background kills the moment the app is backgrounded. That directly
    // breaks the "always-on regardless of playing" guarantee this whole
    // audio_service integration exists for (see this class's own doc comment
    // above). Forcing one synthetic playing:true pulse the first time any
    // real (non-dev-preview) session exists - immediately followed by the
    // real, accurate state below - fires that edge unconditionally,
    // independent of the speaker's actual playback state. The pulse is
    // harmless, not a lasting misrepresentation: the very next line always
    // overwrites it with the real value, and androidStopForegroundOnPause:
    // false (main.dart) means flipping back to `playing: false` right after
    // never demotes the service again - so this only ever promotes, never
    // falsely shows "playing" for longer than the time between these two
    // playbackState updates.
    if (!_forcedInitialForegroundPromotion) {
      _forcedInitialForegroundPromotion = true;
      playbackState.add(playbackState.value.copyWith(
        playing: true,
        processingState: AudioProcessingState.ready,
      ));
    }

    final now = session.nowPlaying;
    final playing = now?.isPlaying ?? false;
    // Same resolved title as the player card's own now-playing line (see
    // SpeakerController.currentPlayingTitle's doc comment for why this - not
    // now.track/stationName - is the real title source: the device is never
    // sent title metadata for anything played from search results, so those
    // fields legitimately come back empty even while genuinely playing).
    // Falling back to a flat "Not playing" whenever no title was resolvable
    // conflated "no title known" with "not playing", which is simply wrong -
    // fall back to the source name instead, and only ever say "Not playing"
    // when it actually isn't.
    final resolvedTitle = controller.currentPlayingTitle(session);
    final title = resolvedTitle ??
        (now?.track?.isNotEmpty ?? false
            ? now!.track!
            : (now?.stationName?.isNotEmpty ?? false)
                ? now!.stationName!
                : playing
                    ? (now?.source?.isNotEmpty ?? false ? now!.source! : 'Playing')
                    : 'Not playing');

    // session.displayTrueTotalSeconds/displayElapsedSeconds - NOT
    // now.hasKnownDuration/now.totalSeconds directly - are the exact same
    // "real" duration/position values the in-app SeekBar widget already
    // shows (see SpeakerSession's own doc comments).
    //
    // A null MediaItem.duration is why the lock-screen progress bar
    // previously showed a frozen "00:00 / 00:00" - Android's media notification
    // template can't render a scaled seek bar without a known total (confirmed
    // via audio_service's own doc comment on MediaAction.seek). A genuinely
    // durationless source (live radio) still gets null here and just won't
    // show a seek bar - that's correct, not a bug, there's no total to show.
    final totalSeconds = session.displayTrueTotalSeconds;
    final elapsedSeconds = session.displayElapsedSeconds ?? 0;

    mediaItem.add(MediaItem(
      id: session.id,
      title: title,
      artist: session.speaker.name,
      duration: (totalSeconds != null && totalSeconds > 0) ? Duration(seconds: totalSeconds) : null,
    ));
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {},
      androidCompactActionIndices: const [0, 1, 2],
      playing: playing,
      processingState: AudioProcessingState.ready,
      // Called again every second for free, since the same displayTickTimer
      // driving this value's notifyListeners() re-triggers this whole sync -
      // that's what makes the lock-screen scrubber actually advance.
      updatePosition: Duration(seconds: elapsedSeconds),
    ));

    // Deliberately NOT declaring androidPlaybackInfo as a remote/absolute
    // volume session (that was tried - see git history - via
    // RemoteAndroidPlaybackInfo + an androidSetRemoteVolume/
    // androidAdjustRemoteVolume override pair forwarding hardware-button
    // presses to the phone's own local stream volume via a MainActivity.kt
    // platform channel). Confirmed live (2026-07-23) that approach still let
    // hardware volume buttons reach the speaker in practice - Android's
    // hardware-key routing for a declared remote/absolute session is
    // OEM/version-dependent and isn't guaranteed to always call
    // androidAdjustRemoteVolume for a button press rather than going
    // straight to androidSetRemoteVolume, so no amount of forwarding logic
    // in THIS class could reliably guarantee separation. Simply never
    // declaring a remote volume session at all sidesteps the whole problem:
    // audio_service/Android default to ordinary LOCAL playback info, so
    // hardware buttons (and the system media panel) only ever touch the
    // phone's own volume, automatically, with no custom code needed - the
    // speaker's real volume is changed ONLY via this app's own on-screen
    // VolumeSlider, exactly like before audio_service was added.
  }

  @override
  Future<void> play() async {
    final controller = _controller;
    final session = _activeSession;
    if (controller == null || session == null) return;
    await controller.sendKey(session, 'PLAY');
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    final session = _activeSession;
    if (controller == null || session == null) return;
    await controller.sendKey(session, 'PAUSE');
  }

  @override
  Future<void> skipToNext() async {
    final controller = _controller;
    final session = _activeSession;
    if (controller == null || session == null) return;
    await controller.transportSkip(session, 1);
  }

  @override
  Future<void> skipToPrevious() async {
    final controller = _controller;
    final session = _activeSession;
    if (controller == null || session == null) return;
    await controller.transportSkip(session, -1);
  }
}
