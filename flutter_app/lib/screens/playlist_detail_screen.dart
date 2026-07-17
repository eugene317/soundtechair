import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../state/speaker_controller.dart';

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        Playlist? playlist;
        try {
          playlist = controller.playlists.firstWhere((p) => p.id == playlistId);
        } catch (_) {
          playlist = null;
        }
        if (playlist == null) {
          // Deleted (e.g. from another screen) while this one was open.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
          return const Scaffold(body: SizedBox.shrink());
        }

        final isActive = controller.activePlaylist?.id == playlistId;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF161616),
            title: Text(playlist.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (action) => _handleMenuAction(context, action, playlist!),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (isActive) _playerBar(context, controller, playlist),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play All'),
                    onPressed: playlist.tracks.isEmpty
                        ? null
                        : () => controller.playPlaylistFrom(playlist!, 0),
                  ),
                ),
              ),
              Expanded(
                child: playlist.tracks.isEmpty
                    ? const Center(child: Text('No tracks yet.', style: TextStyle(color: Colors.grey)))
                    : ReorderableListView.builder(
                        itemCount: playlist.tracks.length,
                        onReorder: (oldIndex, newIndex) =>
                            controller.reorderPlaylistTrack(playlist!.id, oldIndex, newIndex),
                        itemBuilder: (context, i) {
                          final track = playlist!.tracks[i];
                          final playing = controller.isPlaylistTrackActive(track);
                          return Container(
                            key: ValueKey(track.id),
                            color: playing ? const Color(0xFF16311F) : null,
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: track.imageUrl != null
                                      ? Image.network(track.imageUrl!, fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => const Center(child: Text('🎵')))
                                      : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('🎵'))),
                                ),
                              ),
                              title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () => controller.removeTrackFromPlaylist(playlist!.id, track.id),
                                  ),
                                  const Icon(Icons.drag_handle),
                                ],
                              ),
                              onTap: () => controller.playPlaylistFrom(playlist!, i),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _playerBar(BuildContext context, SpeakerController controller, Playlist playlist) {
    final track = controller.activeTrack;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: track?.imageUrl != null
                      ? Image.network(track!.imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(child: Text('🎵')))
                      : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('🎵'))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track?.title ?? '...', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Text('Track ${controller.activeTrackDisplayPosition} of ${controller.activeTrackCount}',
                        style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
          if (controller.nowPlaying?.progressText != null) ...[
            const SizedBox(height: 8),
            if (controller.nowPlaying!.progressFraction != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: controller.nowPlaying!.progressFraction,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF2A2A2A),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
                ),
              ),
            const SizedBox(height: 4),
            Text(controller.nowPlaying!.progressText!,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(Icons.shuffle,
                    color: controller.playlistOrder == PlaylistOrder.shuffle ? const Color(0xFF22C55E) : Colors.grey),
                onPressed: () => controller.setPlaylistOrder(
                    controller.playlistOrder == PlaylistOrder.shuffle ? PlaylistOrder.sequential : PlaylistOrder.shuffle),
              ),
              IconButton(icon: const Icon(Icons.skip_previous), onPressed: controller.playlistPrevious),
              IconButton(
                iconSize: 32,
                icon: Icon(controller.playlistPaused ? Icons.play_circle_fill : Icons.pause_circle_filled),
                onPressed: controller.playlistPlayPause,
              ),
              IconButton(icon: const Icon(Icons.skip_next), onPressed: controller.playlistNext),
              IconButton(
                icon: Icon(
                  controller.playlistRepeat == PlaylistRepeat.loop ? Icons.repeat_on : Icons.repeat,
                  color: controller.playlistRepeat == PlaylistRepeat.loop ? const Color(0xFF22C55E) : Colors.grey,
                ),
                onPressed: controller.togglePlaylistRepeat,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleMenuAction(BuildContext context, String action, Playlist playlist) async {
    final controller = context.read<SpeakerController>();
    if (action == 'rename') {
      final nameCtrl = TextEditingController(text: playlist.name);
      final newName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename Playlist'),
          content: TextField(controller: nameCtrl, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text.trim()), child: const Text('Save')),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty) {
        await controller.renamePlaylist(playlist.id, newName);
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
      if (confirmed == true) {
        await controller.deletePlaylist(playlist.id);
        if (context.mounted) Navigator.of(context).pop();
      }
    }
  }
}
