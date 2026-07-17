import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';
import 'playlist_detail_screen.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  Future<void> _createPlaylist(BuildContext context) async {
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
    if (name == null || name.isEmpty || !context.mounted) return;
    await context.read<SpeakerController>().createPlaylist(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Playlists'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _createPlaylist(context)),
        ],
      ),
      body: Consumer<SpeakerController>(
        builder: (context, controller, _) {
          if (controller.playlists.isEmpty) {
            return const Center(
              child: Text('No playlists yet.\nAdd a YouTube Music result to get started.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.builder(
            itemCount: controller.playlists.length,
            itemBuilder: (context, i) {
              final playlist = controller.playlists[i];
              final firstImage = playlist.tracks.isEmpty ? null : playlist.tracks.first.imageUrl;
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: firstImage != null
                        ? Image.network(firstImage, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(child: Text('🎵')))
                        : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('🎵'))),
                  ),
                ),
                title: Text(playlist.name),
                subtitle: Text('${playlist.tracks.length} tracks'),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'rename') {
                      final nameCtrl = TextEditingController(text: playlist.name);
                      final newName = await showDialog<String>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Rename Playlist'),
                          content: TextField(controller: nameCtrl, autofocus: true),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
                            TextButton(
                              onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text.trim()),
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      );
                      if (newName != null && newName.isNotEmpty && context.mounted) {
                        await context.read<SpeakerController>().renamePlaylist(playlist.id, newName);
                      }
                    } else if (action == 'delete') {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Delete Playlist'),
                          content: Text('Delete "${playlist.name}"? This cannot be undone.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (confirmed == true && context.mounted) {
                        await context.read<SpeakerController>().deletePlaylist(playlist.id);
                      }
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: playlist.id)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
