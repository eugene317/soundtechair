import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/discovery.dart';
import '../state/speaker_controller.dart';
import '../utils/strings.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/custom_station_tile.dart';
import '../widgets/panel_control.dart';
import '../widgets/searching_overlay.dart';
import '../widgets/station_list.dart';
import '../widgets/transport_row.dart';
import '../widgets/volume_slider.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';
import 'wifi_setup_screen.dart';

enum _HomePage { player, tuneIn, youtube }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _radioQueryCtrl = TextEditingController(text: 'Top 40');
  final _ytQueryCtrl = TextEditingController(text: 'Top Hits 2026');
  _HomePage _page = _HomePage.player;

  @override
  void initState() {
    super.initState();
    final controller = context.read<SpeakerController>();
    if (controller.discoveryStatus == DiscoveryStatus.idle) {
      controller.init();
    }
  }

  @override
  void dispose() {
    _radioQueryCtrl.dispose();
    _ytQueryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        if (controller.speaker == null) {
          return const SearchingOverlay();
        }
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
      case _HomePage.youtube:
        return 'YouTube Music';
    }
  }

  Widget _pageContent(SpeakerController controller) {
    switch (_page) {
      case _HomePage.player:
        return _playerPage(controller);
      case _HomePage.tuneIn:
        return _radioSection(controller);
      case _HomePage.youtube:
        return _youtubeSection(controller);
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
            _drawerItem(context, Icons.speaker, 'Player', _HomePage.player),
            _drawerItem(context, Icons.radio, 'Internet Radio (TuneIn)', _HomePage.tuneIn),
            _drawerItem(context, Icons.smart_display, 'YouTube Music', _HomePage.youtube),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Playlists'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistsScreen()));
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

  Widget _drawerItem(BuildContext context, IconData icon, String label, _HomePage page) {
    final selected = _page == page;
    final color = selected ? const Color(0xFF22C55E) : Colors.white;
    return ListTile(
      leading: Icon(icon, color: color),
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
    return Column(
      children: [
        _deviceCard(controller),
        const SizedBox(height: 12),
        const PanelControl(),
        const SizedBox(height: 12),
        const TransportRow(),
        const SizedBox(height: 8),
        const VolumeSlider(),
        if (controller.statusMessage.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(controller.statusMessage, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ] else ...[
          const SizedBox(height: 4),
          const Text(Strings.presetHint, style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
        const SizedBox(height: 12),
        const CustomStationTile(),
      ],
    );
  }

  Widget _deviceCard(SpeakerController controller) {
    final isOn = controller.nowPlaying?.isOn ?? false;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(controller.speaker?.name ?? 'Bose SoundTouch', style: const TextStyle(fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isOn ? const Color(0xFF16311F) : const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isOn ? 'ON' : 'OFF',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOn ? const Color(0xFF22C55E) : Colors.grey),
                ),
              ),
            ],
          ),
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
                child: Text(
                  controller.speakerReachable
                      ? (controller.nowPlaying?.displayText ?? 'Loading...')
                      : Strings.speakerUnreachable,
                  overflow: TextOverflow.ellipsis,
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
        ],
      ),
    );
  }

  Widget _radioSection(SpeakerController controller) {
    return _searchSection(
      queryCtrl: _radioQueryCtrl,
      onSearch: () => controller.searchRadio(_radioQueryCtrl.text.trim()),
      loading: controller.radioLoading,
      error: controller.radioError,
      gridColumns: 3,
      items: controller.radioResults
          .map((r) => StationListItem(
                title: r.name,
                imageUrl: r.image,
                isPlaying: controller.isRadioPlaying(r),
                onTap: () => controller.playRadioResult(r),
              ))
          .toList(),
    );
  }

  Widget _youtubeSection(SpeakerController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.play_circle,
              size: 18,
              color: controller.youtubeAutoPlayNext ? const Color(0xFF22C55E) : Colors.grey,
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Auto-play next', style: TextStyle(fontSize: 12)),
            ),
            Switch(
              value: controller.youtubeAutoPlayNext,
              activeThumbColor: const Color(0xFF22C55E),
              onChanged: (_) => controller.toggleYoutubeAutoPlayNext(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _searchSection(
          queryCtrl: _ytQueryCtrl,
          onSearch: () => controller.searchYoutube(_ytQueryCtrl.text.trim()),
          loading: controller.youtubeLoading,
          error: controller.youtubeError,
          gridColumns: 2,
          gridStyle: StationGridStyle.card,
          items: controller.youtubeResults.asMap().entries.map((entry) {
            final index = entry.key;
            final r = entry.value;
            return StationListItem(
              title: r.title,
              imageUrl: r.thumbnailUrl,
              isPlaying: controller.isYoutubePlaying(r),
              onTap: () => controller.youtubeAutoPlayNext
                  ? controller.playYoutubeResultAt(index)
                  : controller.playYoutubeResult(r),
              trailingAction: IconButton(
                icon: const Icon(Icons.playlist_add, size: 20),
                tooltip: 'Add to playlist',
                onPressed: () => showAddToPlaylistSheet(context, r),
              ),
            );
          }).toList(),
        ),
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
        StationList(
          loading: loading,
          error: error,
          items: items,
          gridColumns: gridColumns,
          gridStyle: gridStyle,
        ),
      ],
    );
  }
}
