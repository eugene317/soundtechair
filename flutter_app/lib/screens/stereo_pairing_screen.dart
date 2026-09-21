import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';
import '../widgets/searching_overlay.dart';

/// Dedicated pairing management screen, reachable directly from the drawer
/// (not buried inside Settings) - shows currently-paired speakers (with
/// Swap L/R / Un-pair) and unpaired ones (with "Pair as Stereo"), visible
/// even with just 0 or 1 speaker connected so the entry point itself is
/// always discoverable, not just once 2 happen to be connected.
class StereoPairingScreen extends StatelessWidget {
  const StereoPairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: const Color(0xFF161616), title: const Text('Pair Speakers')),
      body: SafeArea(
        child: Consumer<SpeakerController>(
          builder: (context, controller, _) {
            final targets = controller.playbackTargets;
            final paired = targets.where((t) => t.isPaired).toList();
            final unpaired = targets
                .where((t) => !t.isPaired)
                .map((t) => t.solo)
                .where((s) => s.groupPollEverSucceeded)
                .toList();

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (paired.isNotEmpty) ...[
                  const Text('Paired', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final t in paired) _pairedRow(controller, t),
                  const SizedBox(height: 24),
                ],
                const Text('Unpaired', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Only speakers whose /getGroup endpoint has responded at '
                  'least once show up here.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                if (unpaired.isEmpty)
                  const Text(
                    'No unpaired, reachable speakers yet.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else
                  for (final s in unpaired)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.speaker),
                        title: Text(s.speaker.name),
                        subtitle: Text(s.speaker.ip, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: TextButton(
                          onPressed: () => _showPairPicker(context, controller, s, unpaired),
                          child: const Text('Pair as Stereo'),
                        ),
                      ),
                    ),
                const SizedBox(height: 24),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add another speaker'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SearchingOverlay()),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _pairedRow(SpeakerController controller, PlaybackTarget target) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: const Color(0xFF161616),
      child: ListTile(
        leading: const Icon(Icons.check_circle, color: Color(0xFF22C55E)),
        title: Text(target.displayName),
        subtitle: Text(
          'LEFT: ${target.left.speaker.name}   •   RIGHT: ${target.right.speaker.name}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Swap L/R',
              onPressed: () => controller.swapStereoChannels(target),
            ),
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: 'Un-pair',
              onPressed: () => controller.unpairStereo(target),
            ),
          ],
        ),
      ),
    );
  }

  /// The row the user tapped becomes LEFT; whichever other unpaired speaker
  /// they pick here becomes RIGHT - swappable afterward via the paired
  /// row's "Swap L/R" action.
  Future<void> _showPairPicker(
    BuildContext context,
    SpeakerController controller,
    SpeakerSession left,
    List<SpeakerSession> unpaired,
  ) async {
    final others = unpaired.where((s) => s.id != left.id).toList();

    if (others.isEmpty) {
      // Nothing to pair with yet - offer the actual next step (go add one)
      // instead of a picker dialog with zero options in it.
      final goAdd = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Need a second speaker'),
          content: Text('Pairing ${left.speaker.name} needs another connected speaker first.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Add speaker')),
          ],
        ),
      );
      if (goAdd == true && context.mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchingOverlay()));
      }
      return;
    }

    final chosen = await showDialog<SpeakerSession>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Pair ${left.speaker.name} with...'),
        children: [
          for (final s in others)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(s),
              child: Text(s.speaker.name),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await controller.pairAsStereo(left: left, right: chosen);
    }
  }
}
