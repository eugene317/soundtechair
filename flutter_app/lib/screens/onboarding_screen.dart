import 'package:flutter/material.dart';

import 'settings_screen.dart';

/// First-run screen - a thin wrapper over SettingsScreen so a brand-new
/// install always confirms/edits the two server URLs before ever reaching
/// the home screen (which shouldn't attempt search calls with blank/invalid
/// URLs).
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsScreen(isOnboarding: true);
  }
}
