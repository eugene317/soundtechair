import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';
import '../utils/strings.dart';

class CustomStationTile extends StatefulWidget {
  const CustomStationTile({super.key});

  @override
  State<CustomStationTile> createState() => _CustomStationTileState();
}

class _CustomStationTileState extends State<CustomStationTile> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _play() {
    final controller = context.read<SpeakerController>();
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      controller.setStatusMessage(Strings.enterStreamUrlFirst);
      return;
    }
    final name = _nameCtrl.text.trim().isEmpty ? 'Custom Station' : _nameCtrl.text.trim();
    controller.playCustomUrl(url, name);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Add Custom Station', style: TextStyle(fontSize: 14)),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name', isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(labelText: 'Stream URL', isDense: true),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(onPressed: _play, child: const Text('▶ Play')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
