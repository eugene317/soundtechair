import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/discovery.dart';
import '../state/speaker_controller.dart';
import '../utils/strings.dart';
import '../widgets/custom_station_tile.dart';
import '../widgets/panel_control.dart';
import '../widgets/searching_overlay.dart';
import '../widgets/station_list.dart';
import '../widgets/transport_row.dart';
import '../widgets/volume_slider.dart';
import 'settings_screen.dart';
import 'wifi_setup_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _radioQueryCtrl = TextEditingController(text: 'Top 40');
  final _ytQueryCtrl = TextEditingController(text: 'Top Hits 2026');

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
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                children: [
                  _topBar(context),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 20),
                  _radioSection(controller),
                  const SizedBox(height: 20),
                  _youtubeSection(controller),
                  const SizedBox(height: 12),
                  const CustomStationTile(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          const Text('🔊', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(Strings.appTitle, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          IconButton(
            icon: const Icon(Icons.wifi_tethering),
            tooltip: 'Setup new speaker',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WifiSetupScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
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
        ],
      ),
    );
  }

  Widget _radioSection(SpeakerController controller) {
    return _searchSection(
      title: 'Internet Radio (TuneIn)',
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
    return _searchSection(
      title: 'YouTube Music',
      queryCtrl: _ytQueryCtrl,
      onSearch: () => controller.searchYoutube(_ytQueryCtrl.text.trim()),
      loading: controller.youtubeLoading,
      error: controller.youtubeError,
      items: controller.youtubeResults
          .map((r) => StationListItem(
                title: r.title,
                imageUrl: r.thumbnailUrl,
                isPlaying: controller.isYoutubePlaying(r),
                onTap: () => controller.playYoutubeResult(r),
              ))
          .toList(),
    );
  }

  Widget _searchSection({
    required String title,
    required TextEditingController queryCtrl,
    required VoidCallback onSearch,
    required bool loading,
    required String? error,
    required List<StationListItem> items,
    int? gridColumns,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
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
        StationList(loading: loading, error: error, items: items, gridColumns: gridColumns),
      ],
    );
  }
}
