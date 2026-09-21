import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';
import '../widgets/searching_overlay.dart';

/// Multi-room "Group" management screen - a DIFFERENT feature from stereo
/// pairing (see StereoPairingScreen), reachable from the same drawer.
/// Grouping composes with pairing rather than conflicting with it: an
/// already stereo-paired duo shows up here as ONE selectable/groupable unit
/// (via PlaybackTarget.commandTarget), never as two separate halves - see
/// SpeakerController.createZone's own doc comment.
class ZoneGroupingScreen extends StatefulWidget {
  const ZoneGroupingScreen({super.key});

  @override
  State<ZoneGroupingScreen> createState() => _ZoneGroupingScreenState();
}

class _ZoneGroupingScreenState extends State<ZoneGroupingScreen> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: const Color(0xFF161616), title: const Text('Group Speakers')),
      body: SafeArea(
        child: Consumer<SpeakerController>(
          builder: (context, controller, _) {
            final targets = controller.playbackTargets;
            final ungrouped =
                targets.where((t) => t.commandTarget.zonePollEverSucceeded && t.commandTarget.zone == null).toList();

            // Targets sharing the same zone's masterDeviceId belong to the
            // same group card.
            final byMaster = <String, List<PlaybackTarget>>{};
            for (final t in targets) {
              final zone = t.commandTarget.zone;
              if (zone == null) continue;
              byMaster.putIfAbsent(zone.masterDeviceId, () => []).add(t);
            }

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (byMaster.isNotEmpty) ...[
                  const Text('Grouped', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final entry in byMaster.entries) _groupCard(context, controller, entry.key, entry.value, ungrouped),
                  const SizedBox(height: 24),
                ],
                const Text('Ungrouped', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Only speakers whose /getZone endpoint has responded at '
                  'least once show up here.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                if (ungrouped.isEmpty)
                  const Text(
                    'No ungrouped, reachable speakers yet.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else
                  for (final t in ungrouped)
                    CheckboxListTile(
                      value: _selected.contains(t.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(t.id);
                        } else {
                          _selected.remove(t.id);
                        }
                      }),
                      title: Text(t.displayName),
                      secondary: const Icon(Icons.speaker),
                    ),
                if (ungrouped.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: ElevatedButton(
                      onPressed: _selected.length >= 2 ? () => _createGroup(context, controller, ungrouped) : null,
                      child: const Text('Create Group'),
                    ),
                  ),
                ],
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

  Widget _groupCard(
    BuildContext context,
    SpeakerController controller,
    String masterDeviceId,
    List<PlaybackTarget> members,
    List<PlaybackTarget> ungrouped,
  ) {
    final master = members.firstWhere(
      (t) => t.commandTarget.speaker.deviceId == masterDeviceId,
      orElse: () => members.first,
    );
    final slaves = members.where((t) => t.id != master.id).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: const Color(0xFF161616),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${master.displayName} (Master)', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: () => controller.dissolveZone(master),
                  child: const Text('Ungroup'),
                ),
              ],
            ),
            for (final s in slaves)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(s.displayName, style: const TextStyle(fontSize: 13, color: Colors.grey))),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Remove from group',
                      onPressed: () => controller.removeFromZone(master: master, slave: s),
                    ),
                  ],
                ),
              ),
            if (ungrouped.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add speaker'),
                  onPressed: () => _showAddToGroupPicker(context, controller, master, ungrouped),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddToGroupPicker(
    BuildContext context,
    SpeakerController controller,
    PlaybackTarget master,
    List<PlaybackTarget> ungrouped,
  ) async {
    final chosen = await showDialog<PlaybackTarget>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text("Add to ${master.displayName}'s group"),
        children: [
          for (final t in ungrouped)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(t),
              child: Text(t.displayName),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await controller.addToZone(master: master, newSlave: chosen);
    }
  }

  /// The selected speakers become the group; which one is master is asked
  /// right after, matching the requested "select members, then pick the
  /// master" flow (rather than picking a master first).
  Future<void> _createGroup(BuildContext context, SpeakerController controller, List<PlaybackTarget> ungrouped) async {
    final selectedTargets = ungrouped.where((t) => _selected.contains(t.id)).toList();
    if (selectedTargets.length < 2) return;
    final master = await showDialog<PlaybackTarget>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which speaker is the master?'),
        children: [
          for (final t in selectedTargets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(t),
              child: Text(t.displayName),
            ),
        ],
      ),
    );
    if (master == null) return;
    final slaves = selectedTargets.where((t) => t.id != master.id).toList();
    await controller.createZone(master: master, slaves: slaves);
    setState(() => _selected.clear());
  }
}
