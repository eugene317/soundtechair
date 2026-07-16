import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

class TransportRow extends StatelessWidget {
  const TransportRow({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.read<SpeakerController>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _iconButton(Icons.skip_previous, () => controller.sendKey('PREV_TRACK')),
        _iconButton(Icons.play_arrow, () => controller.sendKey('PLAY')),
        _iconButton(Icons.pause, () => controller.sendKey('PAUSE')),
        _iconButton(Icons.skip_next, () => controller.sendKey('NEXT_TRACK')),
        _iconButton(Icons.stop, () => controller.stop(), color: const Color(0xFFFF6666), background: const Color(0xFF3A1A1A)),
      ],
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap, {Color? color, Color? background}) {
    return Material(
      color: background ?? const Color(0xFF1F1F1F),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon, color: color ?? Colors.white, size: 26),
        ),
      ),
    );
  }
}
