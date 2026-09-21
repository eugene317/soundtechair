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

/// Grid tile visual style - `compact` is the small icon+title horizontal
/// rectangle (TuneIn's dense station list); `card` is a bigger album-art-style
/// tile (image on top, title below) for content where a larger thumbnail
/// reads better, e.g. YouTube Music.
enum StationGridStyle { compact, card }

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
  final StationGridStyle gridStyle;

  const StationList({
    super.key,
    required this.loading,
    required this.error,
    required this.items,
    this.gridColumns,
    this.gridStyle = StationGridStyle.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A search error doesn't hide still-playable results from an
        // earlier successful search (or a cache loaded at app startup) -
        // shown as a small banner alongside them, not instead of them. Sits
        // outside the constrained Container below so its presence never
        // changes that Container's own (bounded-vs-shrinkWrap) height
        // handling for the two very different layout modes it supports.
        if (error != null && items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Search failed ($error) - showing previous results.',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ),
        Container(
          constraints: gridColumns == null ? const BoxConstraints(maxHeight: 340) : null,
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            border: Border.all(color: const Color(0xFF2A2A2A)),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(8),
          child: _body(context),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(Strings.searching, style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (error != null && items.isEmpty) {
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
      final isCard = gridStyle == StationGridStyle.card;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: isCard ? 0.78 : 1.7,
        ),
        itemBuilder: (context, i) =>
            isCard ? _StationCardTile(item: items[i]) : _StationGridTile(item: items[i]),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length,
      itemBuilder: (context, i) => _StationTile(item: items[i]),
    );
  }
}

/// A horizontally-scrolling strip of card-style tiles - reuses
/// _StationCardTile's exact visual style (thumbnail filling the tile, small
/// title just below it, still inside the same tile rather than pinned to
/// its bottom edge, plus the green isPlaying border) at a fixed compact
/// size, for a "shortcut row" context (e.g. the player card) rather than a
/// full search results grid.
class StationShortcutStrip extends StatelessWidget {
  final List<StationListItem> items;

  const StationShortcutStrip({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(Strings.nothingFound, style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) => SizedBox(width: 88, child: _StationCardTile(item: items[i])),
      ),
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
      // Requested 2026-07-23 (TuneIn only - this tile style is exclusive to
      // the radio grid, see StationList's own doc comment): the icon now
      // fills the tile's FULL height as a square on the left, not a small
      // fixed-size icon with padding around it - clipBehavior is what keeps
      // the image's hard rectangular corners from poking out past the
      // tile's own rounded ones now that it's flush against three edges.
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: item.onTap,
        child: Container(
          decoration: item.isPlaying
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF22C55E), width: 1.5),
                )
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: item.imageUrl != null
                    ? Image.network(
                        item.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: const Color(0xFF2A2A2A),
                          child: const Center(child: Text('📻')),
                        ),
                      )
                    : Container(color: const Color(0xFF2A2A2A), child: const Center(child: Text('📻'))),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Center(
                    child: Text(
                      item.title,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 10.5),
                    ),
                  ),
                ),
              ),
              if (item.trailingAction != null)
                Padding(padding: const EdgeInsets.only(right: 2), child: Transform.scale(scale: 0.8, child: item.trailingAction)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StationCardTile extends StatelessWidget {
  final StationListItem item;

  const _StationCardTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1F1F1F),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.onTap,
        child: Container(
          decoration: item.isPlaying
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF22C55E), width: 2),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: item.imageUrl != null
                      ? Image.network(
                          item.imageUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, _, _) => Container(
                            color: const Color(0xFF2A2A2A),
                            child: const Center(child: Text('🎵', style: TextStyle(fontSize: 28))),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF2A2A2A),
                          child: const Center(child: Text('🎵', style: TextStyle(fontSize: 28))),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (item.trailingAction != null)
                      Transform.scale(scale: 0.8, child: item.trailingAction),
                  ],
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
