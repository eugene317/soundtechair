import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

class VolumeSlider extends StatelessWidget {
  final SpeakerSession session;

  const VolumeSlider({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        return Row(
          children: [
            const Text('VOL', style: TextStyle(fontSize: 12, color: Colors.grey)),
            Expanded(
              child: Slider(
                min: 0,
                max: 100,
                value: session.displayVolume.toDouble(),
                activeColor: const Color(0xFF22C55E),
                onChanged: (v) => controller.onVolumeInput(session, v.round()),
                onChangeEnd: (v) => controller.onVolumeChange(session, v.round()),
              ),
            ),
            SizedBox(
              width: 28,
              child: Text('${session.displayVolume}', textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }
}
