import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/settings_service.dart';
import 'state/speaker_controller.dart';

void main() {
  runApp(const SoundTouchApp());
}

class SoundTouchApp extends StatelessWidget {
  const SoundTouchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SpeakerController(),
      child: MaterialApp(
        title: 'Bose SoundTouch Control',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF000000),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF22C55E),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const _AppRoot(),
      ),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  final _settingsService = SettingsService();
  late Future<bool> _onboardedFuture;

  @override
  void initState() {
    super.initState();
    _onboardedFuture = _settingsService.hasCompletedOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _onboardedFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return snapshot.data! ? const HomeScreen() : const OnboardingScreen();
      },
    );
  }
}
