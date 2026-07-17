import 'package:flutter/material.dart';

import '../utils/strings.dart';

class StationListItem {
  final String title;
  final String? imageUrl;
  final bool isPlaying;
  final VoidCallback onTap;

  /// Optional trailing widget slot (e.g. an "add to playlist" IconButton, or
  /// a PopupMenuButton for a playlist library row) - a widget slot rather
  /// than a bare icon+callback so different callers can render entirely
  /// different trailing controls without a second bespoke list-row widget.
  final Widget? trailingAction;

  const StationListItem({
    required this.title,
    this.imageUrl,
    this.isPlaying = false,
    required this.onTap,
    this.trailingAction,
  });
}

/// Shared rendering for both the TuneIn and YouTube search sections - with
/// loading/empty/error micro-states matching index.html's
/// station-container/.station-item. Renders as a scrollable vertical list by
/// default, or as a non-scrolling multi-column grid (part of the page's own
/// scroll) when [gridColumns] is set.
class StationList extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<StationListItem> items;
  final int? gridColumns;

  const StationList({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    this.gridColumns,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: gridColumns == null ? const BoxConstraints(maxHeight: 340) : null,
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
    final columns = gridColumns;
    if (columns != null) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 1.7,
        ),
        itemBuilder: (context, i) => _StationGridTile(item: items[i]),
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
              _StationIcon(imageUrl: item.imageUrl, size: 34),
              const SizedBox(width: 12),
              Expanded(child: Text(item.title, overflow: TextOverflow.ellipsis)),
              if (item.trailingAction != null) item.trailingAction!,
            ],
          ),
        ),
      ),
    );
  }
}

class _StationGridTile extends StatelessWidget {
  final StationListItem item;

  const _StationGridTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: item.isPlaying ? const Color(0xFF16311F) : const Color(0xFF1F1F1F),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: item.isPlaying
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF22C55E), width: 1.5),
                )
              : null,
          child: Row(
            children: [
              _StationIcon(imageUrl: item.imageUrl, size: 26),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 10.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StationIcon extends StatelessWidget {
  final String? imageUrl;
  final double size;

  const _StationIcon({required this.imageUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: imageUrl != null
            ? Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(child: Text('📻')),
              )
            : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('📻'))),
      ),
    );
  }
}
