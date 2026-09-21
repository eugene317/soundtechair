import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// Percentage-based hitbox positions (left/top/width/height, all % of the
/// panel image's own box) - calibrated by hand against assets/panel.png (a
/// photo of a physical SoundTouch remote's top panel) using a percentage
/// grid overlay, then visually verified by drawing these exact boxes back
/// onto the photo. This is an invisible-overlay approach: draw the real
/// photo, then place transparent tappable zones exactly where each physical
/// button is drawn in the image - per explicit user direction to match the
/// reference photo's actual button positions/sizes, not approximate them
/// with generic flat widgets.
class _Rect {
  final double left, top, width, height;
  const _Rect(this.left, this.top, this.width, this.height);
}

const _powerRect = _Rect(4, 27, 16, 20);
const _auxRect = _Rect(2, 54, 18, 20);
const _volUpRect = _Rect(81, 27, 16, 20);
const _volDownRect = _Rect(81, 54, 16, 20);

const _presetRects = {
  '1': _Rect(21, 23, 19, 25),
  '2': _Rect(41, 23, 19, 25),
  '3': _Rect(61, 23, 19, 25),
  '4': _Rect(21, 52, 19, 25),
  '5': _Rect(41, 52, 19, 25),
  '6': _Rect(61, 52, 19, 25),
};

class PanelControl extends StatelessWidget {
  final SpeakerSession session;

  const PanelControl({super.key, required this.session});

  // assets/panel.png is 776x436.
  static const _imageAspectRatio = 776 / 436;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: _imageAspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            children: [
              Image.asset('assets/panel.png', fit: BoxFit.fill, width: w, height: h),
              _hitButton(
                _powerRect,
                w,
                h,
                key: const ValueKey('power-hitbox'),
                onTap: (c) => c.sendKey(session, 'POWER'),
                isOn: () => session.nowPlaying?.isOn ?? false,
              ),
              _hitButton(
                _auxRect,
                w,
                h,
                key: const ValueKey('aux-hitbox'),
                onTap: (c) => c.toggleAuxSource(session),
                isOn: () => session.nowPlaying?.source == 'AUX',
              ),
              _hitButton(_volUpRect, w, h, key: const ValueKey('volup-hitbox'), onTap: (c) => c.volStep(session, 5)),
              _hitButton(_volDownRect, w, h, key: const ValueKey('voldown-hitbox'), onTap: (c) => c.volStep(session, -5)),
              for (final entry in _presetRects.entries) _presetButton(entry.key, entry.value, w, h),
            ],
          );
        },
      ),
    );
  }

  Widget _hitButton(
    _Rect r,
    double w,
    double h, {
    Key? key,
    required void Function(SpeakerController c) onTap,
    bool Function()? isOn,
  }) {
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: Consumer<SpeakerController>(
        builder: (context, controller, _) {
          final on = isOn?.call() ?? false;
          return _HitBox(key: key, onTap: () => onTap(controller), color: on ? const Color(0x3822C55E) : null);
        },
      ),
    );
  }

  Widget _presetButton(String num, _Rect r, double w, double h) {
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: _PresetHitBox(key: ValueKey('preset-hitbox-$num'), session: session, presetNum: num),
    );
  }
}

class _HitBox extends StatefulWidget {
  final VoidCallback onTap;
  final Color? color;

  const _HitBox({super.key, required this.onTap, this.color});

  @override
  State<_HitBox> createState() => _HitBoxState();
}

class _HitBoxState extends State<_HitBox> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Container(
        color: _pressed ? const Color(0x5922C55E) : (widget.color ?? Colors.transparent),
      ),
    );
  }
}

/// Preset gesture: tap-to-play only. Holding a preset button used to trigger
/// an in-app "save current station to this preset" action (a synthetic
/// press-wait-release sequence simulating a physical hold) - removed after
/// real-hardware field testing (2026-08-15) showed a preset saved this way
/// was recallable from within the app but NEVER from the speaker's own
/// physical button, while a genuine physical hold (done by hand) worked
/// reliably both ways. Rather than ship a "save" action that silently only
/// half-works, saving is now exclusively a physical action on the speaker
/// itself - see SpeakerController.playRadioResult/toggleFavorite for the
/// app-side alternative (a purely local Favorites list that never touches
/// the device's preset storage, so it's always reliable). A long-press here
/// still shows a hint pointing at the physical button instead of silently
/// doing nothing, since this exact gesture used to do something.
class _PresetHitBox extends StatefulWidget {
  final SpeakerSession session;
  final String presetNum;

  const _PresetHitBox({super.key, required this.session, required this.presetNum});

  @override
  State<_PresetHitBox> createState() => _PresetHitBoxState();
}

class _PresetHitBoxState extends State<_PresetHitBox> {
  Timer? _holdTimer;
  bool _didLongPress = false;
  bool _pressed = false;

  void _start() {
    setState(() => _pressed = true);
    _didLongPress = false;
    _holdTimer = Timer(const Duration(milliseconds: 1500), () {
      _didLongPress = true;
      context
          .read<SpeakerController>()
          .setStatusMessage('To save preset ${widget.presetNum}, hold the button on the speaker itself for a few seconds.');
    });
  }

  void _cancel({bool triggerPlay = true}) {
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() => _pressed = false);
    if (triggerPlay && !_didLongPress) {
      context.read<SpeakerController>().playPreset(widget.session, widget.presetNum);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final playing = widget.session.isPresetPlaying(widget.presetNum);
        Color? overlayColor;
        if (playing) {
          overlayColor = const Color(0x2222C55E);
        } else if (_pressed) {
          overlayColor = const Color(0x5922C55E);
        }
        return GestureDetector(
          onTapDown: (_) => _start(),
          onTapUp: (_) => _cancel(),
          onTapCancel: () => _cancel(triggerPlay: false),
          child: Container(color: overlayColor ?? Colors.transparent),
        );
      },
    );
  }
}
