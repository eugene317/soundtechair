import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// Percentage-based hitbox positions, copied 1:1 from index.html's inline
/// styles (left/top/width/height, all % of the panel image's own box).
class _Rect {
  final double left, top, width, height;
  const _Rect(this.left, this.top, this.width, this.height);
}

const _powerRect = _Rect(8.02, 13.30, 15.21, 17.07);
const _lAuxRect = _Rect(8.02, 30.38, 15.21, 17.29);
const _volUpRect = _Rect(78.28, 13.30, 15.21, 17.07);
const _volDownRect = _Rect(78.28, 30.38, 15.21, 17.29);

const _presetRects = {
  '1': _Rect(23.79, 9.98, 17.98, 21.73),
  '2': _Rect(41.77, 9.98, 17.98, 21.73),
  '3': _Rect(59.75, 9.98, 17.98, 21.73),
  '4': _Rect(23.79, 31.71, 17.98, 20.40),
  '5': _Rect(41.77, 31.71, 17.98, 20.40),
  '6': _Rect(59.75, 31.71, 17.98, 20.40),
};

const _dotWifi = Offset(22.27, 90.91);
const _dotStatus1 = Offset(40.39, 92.68);
const _dotAux = Offset(60.86, 91.80);
const _dotStatus2 = Offset(78.56, 90.91);

class PanelControl extends StatelessWidget {
  const PanelControl({super.key});

  static const _imageAspectRatio = 723 / 451;

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
              _hitButton(context, _powerRect, w, h, onTap: () => context.read<SpeakerController>().sendKey('POWER'), isOn: (c) => c.nowPlaying?.isOn ?? false),
              _hitButton(context, _lAuxRect, w, h, onTap: () => context.read<SpeakerController>().toggleAuxSource()),
              _hitButton(context, _volUpRect, w, h, onTap: () => context.read<SpeakerController>().volStep(5)),
              _hitButton(context, _volDownRect, w, h, onTap: () => context.read<SpeakerController>().volStep(-5)),
              for (final entry in _presetRects.entries) _presetButton(context, entry.key, entry.value, w, h),
              _dot(_dotWifi, w, h, litOf: (c) => c.speakerReachable, color: const Color(0xFF22C55E)),
              _dot(_dotAux, w, h, litOf: (c) => c.nowPlaying?.source == 'AUX', color: const Color(0xFF22C55E)),
              _dot(_dotStatus1, w, h, litOf: (c) => c.nowPlaying?.source == 'BLUETOOTH', color: const Color(0xFF4A9EFF)),
              _dot(_dotStatus2, w, h, litOf: (c) => c.nowPlaying?.isPlaying ?? false, color: const Color(0xFF22C55E)),
            ],
          );
        },
      ),
    );
  }

  Widget _hitButton(
    BuildContext context,
    _Rect r,
    double w,
    double h, {
    required VoidCallback onTap,
    bool Function(SpeakerController c)? isOn,
  }) {
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: Consumer<SpeakerController>(
        builder: (context, controller, _) {
          final on = isOn?.call(controller) ?? false;
          return _HitBox(onTap: onTap, color: on ? const Color(0x3822C55E) : null);
        },
      ),
    );
  }

  Widget _presetButton(BuildContext context, String num, _Rect r, double w, double h) {
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: _PresetHitBox(presetNum: num),
    );
  }

  Widget _dot(
    Offset pos,
    double w,
    double h, {
    required bool Function(SpeakerController c) litOf,
    required Color color,
  }) {
    const size = 10.0;
    return Positioned(
      left: pos.dx / 100 * w - size / 2,
      top: pos.dy / 100 * h - size / 2,
      width: size,
      height: size,
      child: Consumer<SpeakerController>(
        builder: (context, controller, _) {
          final lit = litOf(controller);
          return Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: lit ? color : Colors.transparent,
              boxShadow: lit ? [BoxShadow(color: color, blurRadius: 6, spreadRadius: 1)] : null,
            ),
          );
        },
      ),
    );
  }
}

class _HitBox extends StatefulWidget {
  final VoidCallback onTap;
  final Color? color;

  const _HitBox({required this.onTap, this.color});

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

/// Preset button gesture: tap-to-play vs hold-1500ms-to-save, timing ported
/// exactly from index.html's mousedown/touchstart handlers.
class _PresetHitBox extends StatefulWidget {
  final String presetNum;

  const _PresetHitBox({required this.presetNum});

  @override
  State<_PresetHitBox> createState() => _PresetHitBoxState();
}

class _PresetHitBoxState extends State<_PresetHitBox> {
  Timer? _holdTimer;
  bool _didSave = false;
  bool _pressed = false;

  void _start() {
    setState(() => _pressed = true);
    _didSave = false;
    _holdTimer = Timer(const Duration(milliseconds: 1500), () {
      _didSave = true;
      context.read<SpeakerController>().savePreset(widget.presetNum);
    });
  }

  void _cancel({bool triggerPlay = true}) {
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() => _pressed = false);
    if (triggerPlay && !_didSave) {
      context.read<SpeakerController>().playPreset(widget.presetNum);
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
        final playing = controller.isPresetPlaying(widget.presetNum);
        final saving = controller.savingPresetNums.contains(widget.presetNum);
        Color? overlayColor;
        Border? border;
        if (saving) {
          overlayColor = const Color(0x4DF0A020);
          border = Border.all(color: const Color(0xFFF0A020), width: 2.5);
        } else if (playing) {
          overlayColor = const Color(0x3822C55E);
          border = Border.all(color: const Color(0xFF22C55E), width: 2.5);
        } else if (_pressed) {
          overlayColor = const Color(0x5922C55E);
        }
        return GestureDetector(
          onTapDown: (_) => _start(),
          onTapUp: (_) => _cancel(),
          onTapCancel: () => _cancel(triggerPlay: false),
          child: Container(
            decoration: BoxDecoration(color: overlayColor, border: border),
          ),
        );
      },
    );
  }
}
