import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

class TransportRow extends StatelessWidget {
  final SpeakerSession session;

  const TransportRow({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final controller = context.read<SpeakerController>();
    // Same "is this session ACTUALLY playing right now" signal the display
    // ticker uses (SpeakerController._startSessionTimers) - accounts for the
    // optimistic manuallyPaused flag (set synchronously on tap, before the
    // network round trip), not just the last-polled nowPlaying.isPlaying, so
    // the icon flips the instant the user taps rather than waiting for the
    // next poll to confirm.
    final isPlaying = !session.manuallyPaused && session.nowPlaying?.isPlaying == true;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _iconButton(Icons.skip_previous, () => controller.transportSkip(session, -1)),
        _iconButton(
          isPlaying ? Icons.pause : Icons.play_arrow,
          () => controller.sendKey(session, isPlaying ? 'PAUSE' : 'PLAY'),
        ),
        _iconButton(Icons.skip_next, () => controller.transportSkip(session, 1)),
      ],
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF1F1F1F),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}
