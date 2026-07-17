import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';

/// Generic, model-agnostic control surface. Previously this drew a
/// photorealistic image of one specific SoundTouch 10's top panel with
/// invisible tap-zones placed at percentages matching that exact model's
/// button layout - correct only for that one physical device, and wrong
/// for any other SoundTouch model (10/20/30/Wireless Link/etc.) a
/// different user might have. Presets are a protocol-level feature (keys
/// 1-6 over the XML API) present on every model regardless of how many
/// physical preset buttons it has, so a plain 6-slot grid stays universal.
class PanelControl extends StatelessWidget {
  const PanelControl({super.key});

  // Caps the panel's width so the Expanded toggle buttons and the preset
  // grid stop scaling linearly with window width on tablet/desktop-sized
  // windows (e.g. the app's documented 1280px target). Without this, the
  // Row/Expanded/AspectRatio layout below grows unbounded since neither
  // this widget nor any ancestor (home_screen.dart's player page) applies
  // a max width, producing disproportionately large controls relative to
  // the fixed 44x44 volume-step buttons in the same row. At narrow widths
  // (down to the 344px device target) this constraint is always looser
  // than the width actually available, so it has no effect there.
  static const double _maxWidth = 480;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(16)),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ToggleButton(
                      icon: Icons.power_settings_new,
                      label: 'Power',
                      isOn: (c) => c.nowPlaying?.isOn ?? false,
                      onTap: (c) => c.sendKey('POWER'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ToggleButton(
                      icon: Icons.input,
                      label: 'Aux',
                      isOn: (c) => c.nowPlaying?.source == 'AUX',
                      onTap: (c) => c.toggleAuxSource(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _VolStepButton(icon: Icons.volume_down, delta: -5),
                  const SizedBox(width: 8),
                  _VolStepButton(icon: Icons.volume_up, delta: 5),
                ],
              ),
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('PRESETS', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1)),
              ),
              const SizedBox(height: 6),
              Row(children: [
                for (final n in ['1', '2', '3']) ...[
                  Expanded(child: _PresetButton(num: n)),
                  if (n != '3') const SizedBox(width: 8),
                ],
              ]),
              const SizedBox(height: 8),
              Row(children: [
                for (final n in ['4', '5', '6']) ...[
                  Expanded(child: _PresetButton(num: n)),
                  if (n != '6') const SizedBox(width: 8),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool Function(SpeakerController) isOn;
  final void Function(SpeakerController) onTap;

  const _ToggleButton({required this.icon, required this.label, required this.isOn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final on = isOn(controller);
        return Material(
          color: on ? const Color(0xFF16311F) : const Color(0xFF232323),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onTap(controller),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: on ? const Color(0xFF22C55E) : Colors.white),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(fontSize: 10, color: on ? const Color(0xFF22C55E) : Colors.grey)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VolStepButton extends StatelessWidget {
  final IconData icon;
  final int delta;

  const _VolStepButton({required this.icon, required this.delta});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF232323),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => context.read<SpeakerController>().volStep(delta),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// Preset gesture: tap-to-play vs hold-1500ms-to-save, unchanged from the
/// original image-based hitbox implementation.
class _PresetButton extends StatefulWidget {
  final String num;

  const _PresetButton({required this.num});

  @override
  State<_PresetButton> createState() => _PresetButtonState();
}

class _PresetButtonState extends State<_PresetButton> {
  Timer? _holdTimer;
  bool _didSave = false;
  bool _pressed = false;

  void _start() {
    setState(() => _pressed = true);
    _didSave = false;
    _holdTimer = Timer(const Duration(milliseconds: 1500), () {
      _didSave = true;
      context.read<SpeakerController>().savePreset(widget.num);
    });
  }

  void _cancel({bool triggerPlay = true}) {
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() => _pressed = false);
    if (triggerPlay && !_didSave) {
      context.read<SpeakerController>().playPreset(widget.num);
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
        final playing = controller.isPresetPlaying(widget.num);
        final saving = controller.savingPresetNums.contains(widget.num);
        Color fill = const Color(0xFF232323);
        Color border = Colors.transparent;
        Color text = Colors.white;
        if (saving) {
          fill = const Color(0x33F0A020);
          border = const Color(0xFFF0A020);
          text = const Color(0xFFF0A020);
        } else if (playing) {
          fill = const Color(0x2222C55E);
          border = const Color(0xFF22C55E);
          text = const Color(0xFF22C55E);
        } else if (_pressed) {
          fill = const Color(0x5922C55E);
        }
        return AspectRatio(
          aspectRatio: 1.4,
          child: GestureDetector(
            onTapDown: (_) => _start(),
            onTapUp: (_) => _cancel(),
            onTapCancel: () => _cancel(triggerPlay: false),
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(color: border, width: 2),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(widget.num, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: text)),
            ),
          ),
        );
      },
    );
  }
}
