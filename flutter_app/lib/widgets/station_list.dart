import 'package:flutter/material.dart';

import '../utils/strings.dart';

class StationListItem {
  final String title;
  final String? imageUrl;
  final bool isPlaying;
  final VoidCallback onTap;

  const StationListItem({
    required this.title,
    this.imageUrl,
    this.isPlaying = false,
    required this.onTap,
  });
}

/// Shared vertical list rendering for both the TuneIn and YouTube search
/// sections - icon-or-thumbnail + title cards, with loading/empty/error
/// micro-states matching index.html's station-container/.station-item.
class StationList extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<StationListItem> items;

  const StationList({super.key, required this.loading, required this.error, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 340),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(8),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(Strings.searching, style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('Error: $error', style: const TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(Strings.nothingFound, style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length,
      itemBuilder: (context, i) => _StationTile(item: items[i]),
    );
  }
}

class _StationTile extends StatelessWidget {
  final StationListItem item;

  const _StationTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: item.isPlaying ? const Color(0xFF16311F) : const Color(0xFF1F1F1F),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: item.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: item.isPlaying
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF22C55E), width: 1.5),
                )
              : null,
          child: Row(
            children: [
              _icon(),
              const SizedBox(width: 12),
              Expanded(child: Text(item.title, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _icon() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 34,
        height: 34,
        child: item.imageUrl != null
            ? Image.network(
                item.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(child: Text('📻')),
              )
            : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('📻'))),
      ),
    );
  }
}
