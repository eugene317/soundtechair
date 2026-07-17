import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/search_result.dart';
import '../state/speaker_controller.dart';

/// Bottom sheet opened from a YouTube Music result's "add to playlist" icon.
/// Lists existing playlists (tap = add immediately, no confirmation step -
/// speed matters more than ceremony for a repetitive action) plus a pinned
/// "+ New Playlist" row that creates one and adds the track in a single step.
Future<void> showAddToPlaylistSheet(BuildContext context, YoutubeResult result) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF161616),
    isScrollControlled: true,
    builder: (sheetContext) => _AddToPlaylistSheet(result: result),
  );
}

class _AddToPlaylistSheet extends StatelessWidget {
  final YoutubeResult result;

  const _AddToPlaylistSheet({required this.result});

  Future<void> _createAndAdd(BuildContext context) async {
    final controller = context.read<SpeakerController>();
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final playlist = await controller.createPlaylist(name);
    await controller.addYoutubeResultToPlaylist(playlist.id, result);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Add "${result.title}" to playlist',
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add, color: Color(0xFF22C55E)),
              title: const Text('New Playlist'),
              onTap: () => _createAndAdd(context),
            ),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            Flexible(
              child: Consumer<SpeakerController>(
                builder: (context, controller, _) {
                  if (controller.playlists.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No playlists yet.', style: TextStyle(color: Colors.grey)),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: controller.playlists.length,
                    itemBuilder: (context, i) {
                      final playlist = controller.playlists[i];
                      return ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(playlist.name),
                        subtitle: Text('${playlist.tracks.length} tracks'),
                        onTap: () async {
                          await controller.addYoutubeResultToPlaylist(playlist.id, result);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
