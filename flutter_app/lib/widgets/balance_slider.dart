import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// L/R balance control for a stereo-paired target - only meaningful (and
/// only ever shown by the caller) when `target.isPaired`. Always commands
/// `target.left` regardless of which side is master - see
/// SpeakerController.onBalanceInput's doc comment.
class BalanceSlider extends StatelessWidget {
  final PlaybackTarget target;

  const BalanceSlider({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final value = target.left.balanceValue;
        final label = value == 0 ? 'C' : (value < 0 ? 'L${-value}' : 'R$value');
        return Row(
          children: [
            const Text('BAL', style: TextStyle(fontSize: 12, color: Colors.grey)),
            Expanded(
              child: Slider(
                min: -50,
                max: 50,
                value: value.toDouble(),
                activeColor: const Color(0xFF22C55E),
                onChanged: (v) => controller.onBalanceInput(target, v.round()),
                onChangeEnd: (v) => controller.onBalanceChange(target, v.round()),
              ),
            ),
            SizedBox(
              width: 28,
              child: Text(label, textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }
}
