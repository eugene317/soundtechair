import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

class VolumeSlider extends StatelessWidget {
  const VolumeSlider({super.key});

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
                value: controller.displayVolume.toDouble(),
                activeColor: const Color(0xFF22C55E),
                onChanged: (v) => controller.onVolumeInput(v.round()),
                onChangeEnd: (v) => controller.onVolumeChange(v.round()),
              ),
            ),
            SizedBox(
              width: 28,
              child: Text('${controller.displayVolume}', textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }
}
