import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/soundtouch_audio_handler.dart';
import 'state/speaker_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 13+ shows nothing at all for a foreground-service notification
  // (audio_service's lock-screen player included) unless this is granted -
  // there's no other prompt for it anywhere else in this app, and silently
  // skipping it wouldn't fail loudly, it would just leave the player invisible.
  await Permission.notification.request();

  // Created once, here, rather than via ChangeNotifierProvider's own lazy
  // create: callback - SoundTouchAudioHandler needs this EXACT instance
  // (not a fresh one built lazily inside the widget tree later) so it can
  // both read now-playing state from it and issue play/pause/skip commands
  // back through it. See SoundTouchAudioHandler's own doc comment for why
  // registering this handler at all matters (keeps the app's single Flutter
  // engine - and everything running in it - alive as a real Android
  // foreground service).
  final speakerController = SpeakerController();
  await AudioService.init(
    builder: () => SoundTouchAudioHandler()..attach(speakerController),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.airstaffs.soundtechair.channel.audio',
      androidNotificationChannelName: 'SoundTech Air',
      // Never drop out of the foreground state on pause - this app's
      // "playback" can sit paused/idle for long stretches (unlike a normal
      // music app), and the whole point here is to keep the engine (and the
      // preset-button relay riding on it) alive continuously, not just while
      // actively playing.
      androidStopForegroundOnPause: false,
    ),
  );

  runApp(SoundTouchApp(speakerController: speakerController));
}

class SoundTouchApp extends StatelessWidget {
  const SoundTouchApp({required this.speakerController, super.key});

  final SpeakerController speakerController;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: speakerController,
      child: MaterialApp(
        title: 'SoundTech Air',
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
        // Straight to HomeScreen, even on a fresh install - it already
        // calls SpeakerController.init() itself (guarded so it's a no-op if
        // already done) and falls into its own SearchingOverlay when
        // sessions is empty. An IntroVideoScreen (playing assets/introtest.mp4
        // once before this) briefly sat here instead - removed 2026-07-25 per
        // direct feedback to drop the intro video from launch entirely.
        home: const HomeScreen(),
      ),
    );
  }
}
