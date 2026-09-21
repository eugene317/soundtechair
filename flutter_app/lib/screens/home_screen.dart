import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/search_result.dart';
import '../services/discovery.dart';
import '../state/speaker_controller.dart';
import '../utils/strings.dart';
import '../widgets/balance_slider.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/panel_control.dart';
import '../widgets/rename_speaker_dialog.dart';
import '../widgets/searching_overlay.dart';
import '../widgets/seek_bar.dart';
import '../widgets/station_list.dart';
import '../widgets/transport_row.dart';
import '../widgets/volume_slider.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';
import 'stereo_pairing_screen.dart';
import 'zone_grouping_screen.dart';
import 'wifi_setup_screen.dart';

enum _HomePage { player, tuneIn }

/// Where a "Play" tap in the TuneIn tab currently goes - see
/// _HomeScreenState._resolveDestination's own doc comment for why this
/// exists as a separate, UI-only concept alongside PlaybackTarget rather
/// than folding "the phone" into PlaybackTarget/SpeakerSession itself.
sealed class _PlayDestination {
  const _PlayDestination();
}

class _SpeakerDestination extends _PlayDestination {
  final PlaybackTarget target;
  const _SpeakerDestination(this.target);
}

class _PhoneDestination extends _PlayDestination {
  const _PhoneDestination();
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _radioQueryCtrl = TextEditingController();
  _HomePage _page = _HomePage.player;

  /// Which playback target (solo speaker, stereo pair, or this device's own
  /// phone-streaming - see _PlayDestination) radio "Play" actions target,
  /// whenever there's more than one available. Stores either a
  /// PlaybackTarget.id or [_phoneDestinationId], resolved against the live
  /// target list on every build (see _resolveTarget/_resolveDestination)
  /// rather than trusted directly, since the target this id pointed at may
  /// have been forgotten/disconnected/unpaired.
  String? _targetSessionId;

  /// Sentinel _targetSessionId value meaning "the phone", not a real
  /// PlaybackTarget.id - deviceId/ip-derived PlaybackTarget ids are never
  /// empty (see SpeakerInfo), so this can never collide with a real one.
  static const _phoneDestinationId = '__phone__';

  /// Decided ONCE (first build after init), never re-derived from
  /// `sessions.isEmpty` on later builds - otherwise connecting a speaker
  /// from the discovery screen would immediately swap this whole screen
  /// away from under the user the instant `sessions` stops being empty,
  /// which is exactly the auto-redirect this field exists to prevent.
  /// Flips to false only when the user explicitly taps "Continue to Player".
  bool? _showDiscovery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final controller = context.read<SpeakerController>();
    if (controller.discoveryStatus == DiscoveryStatus.idle) {
      controller.init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _radioQueryCtrl.dispose();
    super.dispose();
  }

  /// Catches a speaker whose IP changed while the app was backgrounded
  /// (WiFi setup done from the home screen while this screen sat behind
  /// it, a router reboot overnight, etc.) - re-checking right when the user
  /// actually comes back to look at the app is a much faster path to
  /// recovery than waiting for the background retry timer's own cadence
  /// (see SpeakerController._scanForSpeakers) to happen to land soon after.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<SpeakerController>().discoverMoreSpeakers();
    }
  }

  /// One-shot per cold app launch - flips true the first time
  /// [_maybeAutoOpenRemote] actually pushes RemoteScreen, so navigating back
  /// from it (or any later rebuild) never re-triggers the auto-open.
  bool _didAutoOpenRemote = false;

  /// Settings' "Open Remote by default" toggle - only ever fires once a
  /// speaker is ACTUALLY connected (this is called from build() right after
  /// the discovery gate above, which guarantees controller.sessions is
  /// non-empty by the time control reaches here - see SearchingOverlay's own
  /// "Continue to Player" button, only ever shown once sessions.isNotEmpty).
  /// A fresh install/no-speaker-yet launch is completely unaffected - it
  /// sits on the normal speaker scan exactly as it always has, regardless
  /// of this setting.
  void _maybeAutoOpenRemote(SpeakerController controller) {
    if (_didAutoOpenRemote) return;
    if (!controller.settings.openRemoteByDefault) return;
    if (controller.sessions.isEmpty) return;
    _didAutoOpenRemote = true;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteScreen()));
  }

  PlaybackTarget? _resolveTarget(SpeakerController controller) {
    final targets = controller.playbackTargets;
    if (targets.isEmpty) return null;
    final id = _targetSessionId;
    if (id != null) {
      for (final t in targets) {
        if (t.id == id) return t;
      }
    }
    return targets.first;
  }

  /// Same idea as [_resolveTarget], widened to also cover "this device's own
  /// phone-streaming" as a selectable Play destination (see
  /// SpeakerController.playOnPhone) - used only where a plain PlaybackTarget
  /// isn't enough (the TuneIn tab's search/genre/favorites/recently-played
  /// rows), not by things that are inherently speaker-only (MiniPlayerBar,
  /// each speaker card's own _playerRecommendations, which already knows
  /// exactly which session it belongs to).
  _PlayDestination? _resolveDestination(SpeakerController controller) {
    final targets = controller.playbackTargets;
    final id = _targetSessionId;
    if (id == _phoneDestinationId && controller.phoneStreamingEnabled) return const _PhoneDestination();
    if (id != null) {
      for (final t in targets) {
        if (t.id == id) return _SpeakerDestination(t);
      }
    }
    if (targets.isNotEmpty) return _SpeakerDestination(targets.first);
    if (controller.phoneStreamingEnabled) return const _PhoneDestination();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        _showDiscovery ??= controller.sessions.isEmpty;
        if (_showDiscovery == true) {
          return SearchingOverlay(onDone: () => setState(() => _showDiscovery = false));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoOpenRemote(controller));
        // Only shown away from the Player page itself - the Player page
        // already has the full controls on-screen, so a second mini player
        // stacked on top of them would be redundant.
        final miniPlayerTarget = _page == _HomePage.tuneIn ? _resolveTarget(controller) : null;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF161616),
            title: Text(_pageTitle),
          ),
          drawer: _buildDrawer(context),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: _pageContent(controller),
            ),
          ),
          bottomNavigationBar: miniPlayerTarget == null
              ? null
              : MiniPlayerBar(
                  session: miniPlayerTarget.commandTarget,
                  onExpand: () => setState(() => _page = _HomePage.player),
                ),
        );
      },
    );
  }

  String get _pageTitle {
    switch (_page) {
      case _HomePage.player:
        return Strings.appTitle;
      case _HomePage.tuneIn:
        return 'Internet Radio (TuneIn)';
    }
  }

  Widget _pageContent(SpeakerController controller) {
    switch (_page) {
      case _HomePage.player:
        return _playerPage(controller);
      case _HomePage.tuneIn:
        return _radioSection(controller);
    }
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF161616),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('🔊 ${Strings.appTitle}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            _drawerItem(context, const Icon(Icons.speaker), 'Player', _HomePage.player),
            _drawerItem(context, null, 'Internet Radio (TuneIn)', _HomePage.tuneIn),
            ListTile(
              leading: const Icon(Icons.settings_remote),
              title: const Text('Remote'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteScreen()));
              },
            ),
            const Divider(color: Color(0xFF2A2A2A)),
            ListTile(
              leading: const Icon(Icons.wifi_tethering),
              title: const Text('Setup New Speaker'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WifiSetupScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Add / rescan speakers'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchingOverlay()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.speaker_group),
              title: const Text('Pair speakers'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StereoPairingScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('Group speakers'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ZoneGroupingScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Null for "nothing recognized as playing from a search result" (AUX, a
  /// preset, standby, etc.) - the player card's source indicator hides
  /// itself entirely in that case rather than showing something misleading.
  String? _sourceLabel(bool isPlayingRadio) => isPlayingRadio ? 'TuneIn' : null;

  Widget _drawerItem(BuildContext context, Widget? leading, String label, _HomePage page) {
    final selected = _page == page;
    final color = selected ? const Color(0xFF22C55E) : Colors.white;
    return ListTile(
      leading: leading == null ? null : IconTheme.merge(data: IconThemeData(color: color), child: leading),
      title: Text(label, style: TextStyle(color: color)),
      selected: selected,
      selectedTileColor: const Color(0xFF16311F),
      onTap: () {
        setState(() => _page = page);
        Navigator.of(context).pop();
      },
    );
  }

  Widget _playerPage(SpeakerController controller) {
    if (controller.playbackTargets.isEmpty && !controller.phoneStreamingEnabled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            const Text('No speakers connected.', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.speaker),
              label: const Text('Find speakers'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchingOverlay())),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final target in controller.playbackTargets) ...[
          _speakerCard(controller, target, key: ValueKey(target.id)),
          const SizedBox(height: 12),
        ],
        if (controller.phoneStreamingEnabled) ...[
          _phonePlayerCard(controller),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// This app is designed for phone-sized screens, so below 600 logical
  /// pixels wide (every real phone, including a folded Z Flip's narrow
  /// cover screen) this returns the full available width unchanged -
  /// exactly today's behavior, nothing new to adjust there. A fixed 480px
  /// (then a two-step 560/720 attempt) cap above that left every player
  /// card looking like a small, un-adjusted box floating in a sea of empty
  /// space on an actual tablet - reported twice as still not using the
  /// screen. Scaling continuously with the real width (rather than a
  /// couple of fixed jumps) instead of stopping at a flat 720px keeps that
  /// filled-in feel as the screen keeps growing, while the clamp still
  /// stops a single-column card from stretching edge-to-edge into
  /// something absurdly wide and hard to scan on a large tablet.
  double _cardMaxWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 600) return width;
    return (width * 0.82).clamp(560, 1000);
  }

  /// Deliberately much simpler than _speakerCard - no PanelControl button
  /// grid (that photorealistic panel represents a real physical SoundTouch
  /// unit's layout, which doesn't exist here), no presets, no volume slider
  /// tied to a device. Just what a normal media player needs: what's
  /// playing, and previous/play-pause/next - see
  /// SpeakerController.phoneSkip's doc comment for what "next/previous"
  /// means with no physical device or track queue behind it.
  Widget _phonePlayerCard(SpeakerController controller) {
    final now = controller.phoneNowPlaying;
    final playing = controller.phoneIsPlaying;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _cardMaxWidth(context)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.smartphone, size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Phone Streaming', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  // Removing just turns phoneStreamingEnabled back off - see
                  // SpeakerController.disablePhoneStreaming's own doc comment
                  // for why that alone is enough to make the "Stream on Your
                  // Phone" button reappear back on the Speakers screen, with
                  // no separate "undo" state to manage here.
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    onPressed: controller.disablePhoneStreaming,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10)),
                    child: const Center(child: Text('🎵', style: TextStyle(fontSize: 20))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      now?.name ?? 'Nothing playing - pick a station from TuneIn',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 32,
                    onPressed: () => controller.phoneSkip(forward: false),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                    iconSize: 52,
                    color: const Color(0xFF22C55E),
                    onPressed: now == null ? null : controller.phoneTogglePlayPause,
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    iconSize: 32,
                    onPressed: () => controller.phoneSkip(forward: true),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('VOL', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: 100,
                      value: controller.phoneVolume.toDouble(),
                      activeColor: const Color(0xFF22C55E),
                      onChanged: (v) => controller.setPhoneVolume(v.round()),
                    ),
                  ),
                  SizedBox(width: 28, child: Text('${controller.phoneVolume}', textAlign: TextAlign.right)),
                ],
              ),
              const SizedBox(height: 16),
              for (final label in SpeakerController.phoneRecommendations.keys) ...[
                _labeledStrip(
                  label: label.toUpperCase(),
                  loading: controller.phoneGenreLoading[label] ?? false,
                  items: _stationItems(
                    controller,
                    isPlaying: controller.isPhonePlaying,
                    onTap: controller.playOnPhone,
                    // Deliberately the raw (unfiltered) results - see
                    // SpeakerController.phoneGenreResults' own doc comment
                    // for why https stations stay visible here, unlike the
                    // speaker-facing genre rows.
                    results: controller.phoneGenreResults[label] ?? const [],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One unified card per playback target: name/status, now-playing + seek
  /// bar, the power/aux/volume-step/preset-1-6 grid, transport row, volume
  /// slider, and a custom-station quick-entry - all in one box rather than a
  /// stack of separate ones. For a stereo-paired target, adds an explicit
  /// LEFT/RIGHT row naming each physical speaker plus Swap/Un-pair actions;
  /// every control below still targets `target.commandTarget` alone (the
  /// pair's master), same as a solo speaker.
  Widget _speakerCard(SpeakerController controller, PlaybackTarget target, {Key? key}) {
    final session = target.commandTarget;
    final isOn = session.nowPlaying?.isOn ?? false;
    final sourceLabel = _sourceLabel(controller.isPlayingRadio(session));
    return Center(
      key: key,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _cardMaxWidth(context)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            target.displayName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Paired targets show a computed "Left + Right" name
                        // (see PlaybackTarget.displayName) - there's no single
                        // entity there to rename, so this only ever appears
                        // for a solo speaker. See showRenameSpeakerDialog's
                        // doc comment for the "always changeable later" half
                        // of the naming design (the other half - optional at
                        // first connect - lives in SearchingOverlay).
                        if (!target.isPaired)
                          IconButton(
                            icon: const Icon(Icons.edit, size: 16, color: Colors.grey),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => showRenameSpeakerDialog(context, target.solo),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isOn ? const Color(0xFF16311F) : const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isOn ? 'ON' : 'OFF',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isOn ? const Color(0xFF22C55E) : Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
              // A solo target's own commandTarget going unreachable doesn't
              // split into anything else the way a paired target's master
              // does (see playbackTargets' unreachableStreak >= 2 handling
              // just above _speakerCard) - without this, a speaker that's
              // been factory-reset or unplugged just sits here forever
              // looking like a completely normal, connected card (name,
              // ON/OFF badge, and every control still rendering as if
              // nothing's wrong) apart from one subtle title-text swap
              // lower down. 12 failed 5-second polls (~60s) is well past
              // any transient WiFi blip but still catches a real reset
              // quickly - deliberately a much longer bar than the paired
              // case's threshold of 2, since this one is user-facing and
              // false alarms here would be far more visible/annoying. If
              // this is still showing 60s later, SpeakerController.refreshStatus's
              // own _autoRescanUnreachableStreak threshold removes the card
              // automatically - this button just lets an impatient user
              // skip that wait instead of being the only way out.
              if (!target.isPaired && session.unreachableStreak >= 12) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A2A10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFF0A020)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off, color: Color(0xFFF0A020), size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "Hasn't responded in over a minute - it may have been reset or dropped off WiFi. Removing it automatically shortly.",
                          style: TextStyle(fontSize: 12, color: Color(0xFFF0A020)),
                        ),
                      ),
                      TextButton(
                        onPressed: () => controller.rescanSpeaker(session),
                        child: const Text('Remove now', style: TextStyle(fontSize: 12, color: Color(0xFFF0A020))),
                      ),
                    ],
                  ),
                ),
              ],
              if (target.isPaired) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text('◀ LEFT: ${target.left.speaker.name}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey), overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: Text('RIGHT: ${target.right.speaker.name} ▶',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
                if (!(target.left.id == session.id ? target.right : target.left).speakerReachable) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${(target.left.id == session.id ? target.right : target.left).speaker.name} is unreachable',
                    style: const TextStyle(fontSize: 11, color: Color(0xFFF0A020)),
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => controller.swapStereoChannels(target),
                      child: const Text('Swap L/R', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => controller.unpairStereo(target),
                      child: const Text('Un-pair', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                BalanceSlider(target: target),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10)),
                    child: const Center(child: Text('🎵', style: TextStyle(fontSize: 20))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    // Prefer the real resolved title (e.g. "Lambing (Official
                    // Music Video)") over the raw device status text - the
                    // device itself never reports a usable track/station
                    // name for anything played from search results (see
                    // SpeakerController.currentPlayingTitle's own doc
                    // comment for why), so falling back to displayText
                    // (source + playStatus, e.g. "INTERNET_RADIO
                    // (PLAY_STATE)") only ever applies to AUX/standby/an
                    // unmatched preset - cases with no better title to show.
                    child: Text(
                      session.speakerReachable
                          ? (controller.currentPlayingTitle(session) ?? session.nowPlaying?.displayText ?? 'Loading...')
                          : Strings.speakerUnreachable,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (session.displayProgressText != null) ...[
                const SizedBox(height: 8),
                SeekBar(session: session),
              ],
              if (sourceLabel != null) ...[
                const SizedBox(height: 10),
                Center(
                  child: Text(sourceLabel, style: const TextStyle(fontSize: 13, color: Colors.grey)),
                ),
              ],
              const SizedBox(height: 12),
              PanelControl(session: session),
              const SizedBox(height: 12),
              TransportRow(session: session),
              const SizedBox(height: 8),
              VolumeSlider(session: session),
              if (session.statusMessage.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(session.statusMessage, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ] else ...[
                const SizedBox(height: 4),
                const Text(Strings.presetHint, style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
              const SizedBox(height: 12),
              _playerRecommendations(controller, session),
            ],
          ),
        ),
      ),
    );
  }

  /// Recently Played + genre rows, right on the player card next to the
  /// preset 1-6 grid (PanelControl above) - so there's always something to
  /// tap straight into the moment the user lands on the Player page, without
  /// having to first switch to the TuneIn tab. Same rows/data as the TuneIn
  /// tab's _radioSection (see SpeakerController.genreResults/recentlyPlayed,
  /// already loaded once from init - no extra fetch triggered by showing
  /// them here too), just rendered a second time for this session so both
  /// entry points stay in sync automatically.
  Widget _playerRecommendations(SpeakerController controller, SpeakerSession session) {
    List<StationListItem> items(Iterable<RadioResult> results) => _stationItems(
          controller,
          isPlaying: (r) => controller.isRadioPlaying(session, r),
          onTap: (r) => controller.playRadioResult(session, r),
          results: results,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.favorites.isNotEmpty) ...[
          _labeledStrip(label: 'FAVORITES', items: items(controller.favorites)),
          const SizedBox(height: 16),
        ],
        if (controller.recentlyPlayed.isNotEmpty) ...[
          _labeledStrip(label: 'RECENTLY PLAYED', items: items(controller.recentlyPlayed)),
          const SizedBox(height: 16),
        ],
        for (final genre in SpeakerController.genres) ...[
          _labeledStrip(
            label: genre.toUpperCase(),
            loading: controller.genreLoading[genre] ?? false,
            items: items(controller.visibleGenreResults(genre)),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// Shown whenever more than one Play destination is available (multiple
  /// speakers, a stereo pair, and/or this device's own phone-streaming), so
  /// "Play" on a shared search result has an unambiguous target instead of
  /// silently picking one. A stereo pair collapses to one chip here, same as
  /// it collapses to one card on the Player page.
  Widget _targetSpeakerSelector(SpeakerController controller, _PlayDestination current) {
    final targets = controller.playbackTargets;
    final totalDestinations = targets.length + (controller.phoneStreamingEnabled ? 1 : 0);
    if (totalDestinations < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final t in targets)
            ChoiceChip(
              label: Text(t.displayName),
              selected: current is _SpeakerDestination && current.target.id == t.id,
              onSelected: (_) => setState(() => _targetSessionId = t.id),
            ),
          if (controller.phoneStreamingEnabled)
            ChoiceChip(
              label: const Text('Phone'),
              selected: current is _PhoneDestination,
              onSelected: (_) => setState(() => _targetSessionId = _phoneDestinationId),
            ),
        ],
      ),
    );
  }

  Widget _radioSection(SpeakerController controller) {
    final destination = _resolveDestination(controller);
    if (destination == null) return const SizedBox.shrink();
    List<StationListItem> items(Iterable<RadioResult> results) => _destinationStationItems(controller, destination, results);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _targetSpeakerSelector(controller, destination),
        if (controller.favorites.isNotEmpty) ...[
          _labeledStrip(label: 'FAVORITES', items: items(controller.favorites)),
          const SizedBox(height: 16),
        ],
        if (controller.recentlyPlayed.isNotEmpty) ...[
          _labeledStrip(label: 'RECENTLY PLAYED', items: items(controller.recentlyPlayed)),
          const SizedBox(height: 16),
        ],
        // The search grid only ever shows an ACTUAL user-initiated search -
        // the untouched startup default (see radioResultsAreDefault's doc
        // comment) is deliberately never shown here, so this stays a clean
        // "type something, get results" box instead of mixing in
        // recommendations. Recommendations live entirely in the genre rows
        // below instead - a separate portion, not blended into search.
        _searchSection(
          queryCtrl: _radioQueryCtrl,
          onSearch: () => controller.searchRadio(_radioQueryCtrl.text.trim()),
          loading: controller.radioLoading,
          error: controller.radioError,
          gridColumns: 3,
          resultsLabel: controller.radioResultsAreDefault ? null : 'SEARCH RESULTS FOR "${controller.lastRadioQuery}"',
          items: controller.radioResultsAreDefault ? const [] : items(controller.visibleRadioResults),
        ),
        const SizedBox(height: 16),
        for (final genre in SpeakerController.genres) ...[
          _labeledStrip(
            label: genre.toUpperCase(),
            loading: controller.genreLoading[genre] ?? false,
            items: items(controller.visibleGenreResults(genre)),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// Shared StationListItem mapping for any RadioResult list - used by both
  /// the TuneIn tab (_radioSection, via _destinationStationItems) and the
  /// Player page's own per-speaker recommendation rows (_playerRecommendations),
  /// so genre/recently-played results behave identically (same
  /// highlight-if-playing, same tap-to-play) no matter which page they're
  /// shown on. Takes plain callbacks rather than a session/destination
  /// directly so this one helper serves both "always this specific speaker"
  /// callers and "whichever destination is currently selected" callers alike.
  /// Every tile also gets a favorite-toggle heart (see
  /// SpeakerController.toggleFavorite) so a station can be favorited from
  /// anywhere it shows up, not just from a dedicated Favorites row.
  List<StationListItem> _stationItems(
    SpeakerController controller, {
    required bool Function(RadioResult) isPlaying,
    required void Function(RadioResult) onTap,
    required Iterable<RadioResult> results,
  }) =>
      results
          .map((r) => StationListItem(
                title: r.name,
                imageUrl: r.image,
                isPlaying: isPlaying(r),
                onTap: () => onTap(r),
                trailingAction: IconButton(
                  icon: Icon(
                    controller.isFavorite(r) ? Icons.favorite : Icons.favorite_border,
                    size: 18,
                    color: controller.isFavorite(r) ? const Color(0xFF22C55E) : Colors.grey,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => controller.toggleFavorite(r),
                ),
              ))
          .toList();

  /// _stationItems bound to whichever destination is currently selected in
  /// the TuneIn tab (see _resolveDestination) - a real speaker, or this
  /// device's own phone-streaming.
  List<StationListItem> _destinationStationItems(
    SpeakerController controller,
    _PlayDestination destination,
    Iterable<RadioResult> results,
  ) {
    return switch (destination) {
      _SpeakerDestination(:final target) => _stationItems(
          controller,
          isPlaying: (r) => controller.isRadioPlaying(target.commandTarget, r),
          onTap: (r) => controller.playRadioResult(target.commandTarget, r),
          results: results,
        ),
      _PhoneDestination() => _stationItems(
          controller,
          isPlaying: controller.isPhonePlaying,
          onTap: controller.playOnPhone,
          results: results,
        ),
    };
  }

  /// One "Recently Played" or genre-browse row: a small grey label above a
  /// horizontal StationShortcutStrip, the same standard layout most radio-
  /// directory apps use for browsable rows. Renders nothing while a genre is
  /// still loading and has no cached results yet (rather than a flash of
  /// "no results found"), and nothing at all once loaded if it truly came
  /// back empty - there's nothing useful to show either way.
  Widget _labeledStrip({required String label, required List<StationListItem> items, bool loading = false}) {
    if (items.isEmpty) {
      if (!loading) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1)),
          const SizedBox(height: 6),
          const SizedBox(
            height: 108,
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1)),
        const SizedBox(height: 6),
        StationShortcutStrip(items: items),
      ],
    );
  }

  Widget _searchSection({
    required TextEditingController queryCtrl,
    required VoidCallback onSearch,
    required bool loading,
    required String? error,
    required List<StationListItem> items,
    int? gridColumns,
    StationGridStyle gridStyle = StationGridStyle.compact,
    String? resultsLabel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: queryCtrl,
                onSubmitted: (_) => onSearch(),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: onSearch, child: const Text('Search')),
          ],
        ),
        const SizedBox(height: 8),
        // resultsLabel is null specifically when the user hasn't searched
        // yet (see SpeakerController.radioResultsAreDefault's doc comment) -
        // in that case skip the label AND the grid entirely, rather than
        // showing anything that reads as "you searched for something."
        // Recommendations live in the genre rows below instead.
        if (resultsLabel != null) ...[
          Text(resultsLabel, style: const TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1)),
          const SizedBox(height: 6),
          StationList(
            loading: loading,
            error: error,
            items: items,
            gridColumns: gridColumns,
            gridStyle: gridStyle,
          ),
        ],
      ],
    );
  }
}
