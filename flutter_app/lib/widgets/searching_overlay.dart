import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings_screen.dart';
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
                  const SizedBox(height: 24),
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
