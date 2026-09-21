import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// Persistent bottom bar shown on pages other than the main Player page, so
/// playback stays visible/controllable without switching pages - the same
/// standard "mini player" pattern most music/radio apps use. Tapping it (or
/// swiping up on it) opens the full Player page.
class MiniPlayerBar extends StatelessWidget {
  final SpeakerSession session;
  final VoidCallback onExpand;

  const MiniPlayerBar({super.key, required this.session, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final now = session.nowPlaying;
        final playing = now?.isPlaying ?? false;
        final title = controller.currentPlayingTitle(session) ?? now?.displayText ?? 'Nothing playing';
        return GestureDetector(
          onTap: onExpand,
          // A real swipe-up gesture - primaryVelocity is negative when the
          // drag ends moving upward. A small tap/jitter won't cross this
          // velocity threshold, only a deliberate swipe will, so this
          // doesn't fight with the plain onTap case above.
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -200) onExpand();
          },
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF161616),
              border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.keyboard_arrow_up, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: const Color(0xFF22C55E)),
                      onPressed: () => controller.sendKey(session, playing ? 'PAUSE' : 'PLAY'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
