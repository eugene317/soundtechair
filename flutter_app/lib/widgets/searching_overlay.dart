import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings_screen.dart';
import '../screens/wifi_setup_screen.dart';
import '../state/speaker_controller.dart';

class SearchingOverlay extends StatelessWidget {
  const SearchingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Color(0xFF22C55E)),
                  const SizedBox(height: 24),
                  Text(controller.discoveryMessage, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    'Bagong speaker na wala pang WiFi?',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Setup New Speaker'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const WifiSetupScreen()),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                    child: const Text('Manual setup / troubleshooting'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
