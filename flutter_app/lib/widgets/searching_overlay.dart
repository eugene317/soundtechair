import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/speaker_info.dart';
import '../screens/wifi_setup_screen.dart';
import '../state/speaker_controller.dart';
import 'rename_speaker_dialog.dart';

/// The speaker discovery/connection screen. Lists every already-connected
/// speaker alongside every discovered-but-not-yet-connected one, each row
/// with its own action - discovery never auto-connects, so finding 2 or 3
/// speakers on the network doesn't silently connect to all of them.
///
/// Shown two ways: as the initial content when nothing is connected yet
/// (via [onDone], a callback that lets the caller switch away once the user
/// is satisfied - see home_screen.dart), or pushed as a normal route (no
/// [onDone]) to add more speakers later without leaving wherever the user
/// already was.
class SearchingOverlay extends StatelessWidget {
  final VoidCallback? onDone;

  const SearchingOverlay({super.key, this.onDone});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final nothingYet = controller.sessions.isEmpty && controller.availableSpeakers.isEmpty;
        return Scaffold(
          appBar: AppBar(backgroundColor: const Color(0xFF161616), title: const Text('Speakers')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (nothingYet) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator(color: Color(0xFF22C55E))),
                  const SizedBox(height: 16),
                  Center(child: Text(controller.discoveryMessage, textAlign: TextAlign.center)),
                  const SizedBox(height: 24),
                ] else ...[
                  for (final session in controller.sessions) _connectedRow(session),
                  for (final info in controller.availableSpeakers) _availableRow(context, controller, info),
                  const SizedBox(height: 16),
                ],
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Scan for speakers'),
                    onPressed: controller.discoverMoreSpeakers,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Brand new speaker with no WiFi yet?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Center(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Setup New Speaker'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const WifiSetupScreen()),
                    ),
                  ),
                ),
                // No physical speaker handy (or just want sound out of the
                // phone itself right now)? Skips speaker discovery entirely -
                // see SpeakerController.enablePhoneStreaming's own doc
                // comment for why this is a small parallel bit of state
                // rather than a fake SpeakerSession. Same auto-navigate
                // shape as connecting a real speaker now has (see
                // _connectAndMaybeRename) - onDone if this is the initial
                // discovery gate (see home_screen.dart), or just pop back if
                // this was instead pushed as a secondary "Add/rescan
                // speakers" route (no discovery gate to flip in that case -
                // the user's already inside the main app).
                if (!controller.phoneStreamingEnabled) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.smartphone),
                      label: const Text('Stream on Your Phone'),
                      onPressed: () {
                        controller.enablePhoneStreaming();
                        if (onDone != null) {
                          onDone!();
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ),
                ],
                if (onDone != null && (controller.sessions.isNotEmpty || controller.phoneStreamingEnabled)) ...[
                  const SizedBox(height: 24),
                  ElevatedButton(onPressed: onDone, child: const Text('Continue to Player')),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _connectedRow(SpeakerSession session) {
    return Card(
      color: const Color(0xFF161616),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.check_circle, color: Color(0xFF22C55E)),
        title: Text(session.speaker.name),
        subtitle: Text(session.speaker.ip, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        trailing: const Text('Connected', style: TextStyle(color: Color(0xFF22C55E), fontSize: 12)),
      ),
    );
  }

  Widget _availableRow(BuildContext context, SpeakerController controller, SpeakerInfo info) {
    return Card(
      color: const Color(0xFF161616),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.speaker, color: Colors.grey),
        title: Text(info.name),
        subtitle: Text(info.ip, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        trailing: ElevatedButton(
          onPressed: () => _connectAndMaybeRename(context, controller, info),
          child: const Text('Connect'),
        ),
      ),
    );
  }

  /// Optional, skippable naming prompt right after a speaker's very first
  /// connect - see showRenameSpeakerDialog's own doc comment for the full
  /// "optional at connect, always changeable later" design this is part of.
  ///
  /// Auto-navigates once this (and the optional rename) is done - onDone if
  /// this is the initial discovery gate, or pop back to wherever the user
  /// came from if this was instead pushed as a secondary "Add/rescan
  /// speakers" route - restoring the app's original "connect a speaker,
  /// land straight on the Player page" behavior, matching "Stream on Your
  /// Phone"'s own auto-navigate right above.
  ///
  /// Deliberately triggered HERE, as a direct one-shot consequence of this
  /// tap's own async chain finishing - never as a reactive `if
  /// (controller.sessions.isNotEmpty) ...` check in build(). A reactive
  /// version would fire on every rebuild of this screen while ANY speaker
  /// is already connected, making it impossible to ever reach this screen
  /// to add a second one (see the "Continue to Player" gating a few lines
  /// up in build(), and _searchForSpeaker's own doc comment in
  /// wifi_setup_screen.dart, for the same "never re-trigger navigation from
  /// state alone" reasoning elsewhere in this flow).
  Future<void> _connectAndMaybeRename(BuildContext context, SpeakerController controller, SpeakerInfo info) async {
    await controller.connectToSpeaker(info);
    if (!context.mounted) return;
    final id = info.deviceId.isNotEmpty ? info.deviceId : info.ip;
    final session = controller.sessionById(id);
    if (session == null) return;
    await showRenameSpeakerDialog(context, session, isInitialSetup: true);
    if (!context.mounted) return;
    if (onDone != null) {
      onDone!();
    } else {
      Navigator.of(context).pop();
    }
  }
}
