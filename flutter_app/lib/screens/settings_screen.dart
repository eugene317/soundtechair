import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/speaker_controller.dart';
import '../utils/strings.dart';
import '../widgets/searching_overlay.dart';
import 'stereo_pairing_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _manualIpCtrl = TextEditingController();
  late bool _openRemoteByDefault;

  @override
  void initState() {
    super.initState();
    _openRemoteByDefault = context.read<SpeakerController>().settings.openRemoteByDefault;
  }

  @override
  void dispose() {
    _manualIpCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Open Remote by default'),
              subtitle: const Text(
                'Reopening the app goes straight to the Remote screen once a speaker is '
                'connected, instead of the Player page. A fresh launch with no speaker '
                'connected yet still goes to speaker scan first, same as always.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              value: _openRemoteByDefault,
              onChanged: (value) async {
                setState(() => _openRemoteByDefault = value);
                await context.read<SpeakerController>().setOpenRemoteByDefault(value);
              },
            ),
            const Divider(height: 32),
            const Text('Speakers', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Consumer<SpeakerController>(
              builder: (context, controller, _) {
                if (controller.sessions.isEmpty) {
                  return const Text('Not connected');
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in controller.sessions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(child: Text('${session.speaker.name} (${session.speaker.ip})')),
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 20),
                              tooltip: 'Rescan',
                              onPressed: () => controller.rescanSpeaker(session),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              tooltip: 'Forget',
                              onPressed: () => controller.forgetSpeaker(session),
                            ),
                          ],
                        ),
                      ),
                    if (controller.statusMessage.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(controller.statusMessage, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                  ],
                );
              },
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchingOverlay())),
              child: const Text('Scan for speakers'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _manualIpCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Speaker IP',
                hintText: '192.168.1.4',
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                final ip = _manualIpCtrl.text.trim();
                if (ip.isNotEmpty) context.read<SpeakerController>().addSpeakerByIp(ip);
              },
              child: const Text('Add speaker by IP'),
            ),
            const Divider(height: 48),
            ElevatedButton.icon(
              icon: const Icon(Icons.speaker_group),
              label: const Text('Pair Speakers'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StereoPairingScreen()),
              ),
            ),
            const Divider(height: 48),
            const Text('About', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.privacy_tip_outlined),
              label: const Text('Privacy Policy'),
              onPressed: _openPrivacyPolicy,
            ),
          ],
        ),
      ),
    );
  }

  // Falls back to a "coming soon" message if Strings.privacyPolicyUrl is ever
  // blank again (e.g. a future rehost that isn't wired up yet) instead of
  // attempting a broken launch, but the real hosted URL is now in place.
  Future<void> _openPrivacyPolicy() async {
    if (Strings.privacyPolicyUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Privacy policy link coming soon.')),
      );
      return;
    }
    final uri = Uri.parse(Strings.privacyPolicyUrl);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $uri')),
      );
    }
  }
}
