import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/now_playing.dart';
import '../state/speaker_controller.dart';

/// Draggable seek bar for YouTube tracks (known duration); falls back to a
/// plain non-interactive progress bar for anything not seekable (radio,
/// custom URLs - continuous/unknown-duration sources with nothing to seek
/// within). Dragging is purely local UI state - the real controller data
/// keeps flowing from polls in the background, and only takes back over
/// once the drag ends and seekTo() has been issued, matching the same
/// drag-guard pattern VolumeSlider already uses for the volume control.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final trueElapsed = controller.displayTrueElapsedSeconds;
        if (trueElapsed == null) return const SizedBox.shrink();

        final total = controller.displayTrueTotalSeconds;
        if (!controller.canSeek || total == null || total <= 0) {
          return _staticProgress(controller);
        }

        final displayValue = (_dragSeconds ?? trueElapsed.toDouble()).clamp(0.0, total.toDouble());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0,
                max: total.toDouble(),
                value: displayValue,
                activeColor: const Color(0xFF22C55E),
                onChanged: (v) => setState(() => _dragSeconds = v),
                onChangeEnd: (v) {
                  controller.seekTo(Duration(seconds: v.round()));
                  setState(() => _dragSeconds = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${NowPlaying.formatSeconds(displayValue.round())} / ${NowPlaying.formatSeconds(total)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _staticProgress(SpeakerController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.displayProgressFraction != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: controller.displayProgressFraction,
              minHeight: 4,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
            ),
          ),
        const SizedBox(height: 4),
        Text(controller.displayProgressText ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
