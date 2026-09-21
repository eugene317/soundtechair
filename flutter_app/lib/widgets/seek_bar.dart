import 'package:flutter/material.dart';

import '../state/speaker_controller.dart';

/// Plain non-interactive progress bar - radio/custom URLs are continuous,
/// unknown-duration sources with nothing to seek within.
class SeekBar extends StatelessWidget {
  final SpeakerSession session;

  const SeekBar({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (session.displayProgressFraction != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: session.displayProgressFraction,
              minHeight: 4,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
            ),
          ),
        const SizedBox(height: 4),
        Text(session.displayProgressText ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
