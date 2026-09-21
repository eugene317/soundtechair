import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:provider/provider.dart';

import '../state/speaker_controller.dart';
import 'settings_screen.dart';

/// Percentage-based hitbox position (left/top/width/height, all % of the
/// remote image's own box) - same convention as PanelControl's own _Rect.
class _RemoteButtonRect {
  final double left, top, width, height;
  const _RemoteButtonRect(this.left, this.top, this.width, this.height);
}

// remotev1.png is 366x906 - no on-screen display graphic, so the button
// grid starts right below the power/AUX row. Calibrated by hand against a
// labeled pixel grid overlay, then verified by drawing these exact boxes
// back onto the photo - same process PanelControl's own _Rect values used.
//
// The left/width values below are NOT plain halves/thirds of 0-100 - a real
// bug found live (2026-07-25): the source PNG has a real ~6.5%/~5.2%
// TRANSPARENT margin baked into its canvas on the left/right (confirmed by
// scanning the file's own alpha channel), which a naive "just split 0-100
// into halves/thirds" calculation silently ignored, so every hitbox's
// highlight visibly overflowed past the button into that transparent
// margin (and the surrounding black Scaffold behind it). Every left/width
// here is instead computed as bodyLeft + fraction * bodyWidth, where
// bodyLeft=6.56 and bodyWidth=88.25 are the image's own true opaque-pixel
// bounds - i.e. percentages of the VISIBLE remote body, not the full
// canvas. Vertical (top/height) values were unaffected (calibrated by
// direct visual row-boundary reading, never assumed symmetric) and are
// unchanged.
const _v1Power = _RemoteButtonRect(6.56, 3.31, 44.13, 12.14);
const _v1Aux = _RemoteButtonRect(50.69, 3.31, 44.13, 12.14);
const _v1Presets = {
  '1': _RemoteButtonRect(6.56, 15.45, 29.42, 11.04),
  '2': _RemoteButtonRect(35.98, 15.45, 29.42, 11.04),
  '3': _RemoteButtonRect(65.42, 15.45, 29.42, 11.04),
  '4': _RemoteButtonRect(6.56, 26.49, 29.42, 11.04),
  '5': _RemoteButtonRect(35.98, 26.49, 29.42, 11.04),
  '6': _RemoteButtonRect(65.42, 26.49, 29.42, 11.04),
};
const _v1VolUp = _RemoteButtonRect(6.56, 37.53, 44.13, 11.04);
const _v1VolDown = _RemoteButtonRect(6.56, 48.57, 44.13, 11.04);
const _v1PlayPause = _RemoteButtonRect(50.69, 37.53, 44.13, 22.08);
const _v1Prev = _RemoteButtonRect(6.56, 59.60, 44.13, 11.04);
const _v1Next = _RemoteButtonRect(50.69, 59.60, 44.13, 11.04);
const _v1ThumbsDown = _RemoteButtonRect(6.56, 70.64, 44.13, 11.04);
const _v1ThumbsUp = _RemoteButtonRect(50.69, 70.64, 44.13, 11.04);

// remotev2.png is 370x932 - same button grid as v1, shifted down to make
// room for its extra on-screen display graphic at the top. Calibrated the
// same way, independently (its proportions aren't a simple offset of v1's) -
// and the SAME transparent-margin correction applies (bodyLeft=6.6,
// bodyWidth=86.1 for this image specifically, confirmed via its own alpha scan).
const _v2Power = _RemoteButtonRect(6.60, 18.24, 43.05, 9.44);
const _v2Aux = _RemoteButtonRect(49.65, 18.24, 43.05, 9.44);
const _v2Presets = {
  '1': _RemoteButtonRect(6.60, 27.68, 28.70, 10.73),
  '2': _RemoteButtonRect(35.30, 27.68, 28.70, 10.73),
  '3': _RemoteButtonRect(64.01, 27.68, 28.70, 10.73),
  '4': _RemoteButtonRect(6.60, 38.41, 28.70, 10.73),
  '5': _RemoteButtonRect(35.30, 38.41, 28.70, 10.73),
  '6': _RemoteButtonRect(64.01, 38.41, 28.70, 10.73),
};
// Vol/PlayPause/Prev/Next re-measured 2026-07-25 (fresh 10px grid read
// directly against the source file) - the original values here had crept
// low enough by the time they reached Prev/Next (~21px/2.25 points short of
// where ThumbsDown/Up actually starts) that direct on-device feedback
// called them out as visibly too low, even though Power/AUX/presets above
// were unaffected. ThumbsDown/Up's own position was NOT touched - it was
// never reported as wrong, and re-verified independently against the same
// fresh grid read.
//
// Still visibly low after that fix, per a SECOND round of direct feedback -
// root cause: _RemoteImage._inset (below) shrinks every hitbox by a further
// fixed +2 top / -4 height, applied uniformly to ALL rects including these.
// Power/AUX/the preset grid happened to have enough slack left over from
// their OWN (less tightly measured) calibration to absorb that shrink
// invisibly, but these four rects were just measured to match their true
// visible edges with NO slack to spare - so the same shared inset pushed
// their EFFECTIVE (post-inset) top edge noticeably below the real button,
// exactly matching "the top of the invisible button is at the middle of the
// real button" reported live.
//
// A THIRD round of direct feedback (screenshots, 2026-07-25) showed the
// compensate-through-_inset approach had gone wrong in the other direction:
// each box had grown genuinely huge (the +4 height compensation, applied on
// top of an already-generous measured height, produced an effective box far
// taller than the icon needed - visibly a large dead zone below each icon
// rather than a snug fit). Abandoned that whole "raw value survives a
// transform" indirection for these five specifically - see
// _RemoteImage._hit's applyInset param and _RemoteLayout.midSectionIsFinalRect.
// These are now the FINAL rect directly (centered on each icon's own true
// position from the fresh grid read, sized like the preset grid's own
// effective ~6.7%/~17% heights, which were never in question) - no further
// transform applied.
//
// VolUp/PlayPause confirmed correct live (2026-07-25) - left untouched.
// VolDown/Prev/Next were NOT, still - eyeballing a labeled grid overlay
// (how every value above was measured) turned out to have real,
// non-trivial error even when it looked right on screen. Replaced that
// with an objective scan for the actual bright icon-glyph pixels
// themselves (scan-icon-band.ps1: average brightness across the whole
// left-column width per row, looking for where it spikes) - gives an exact
// glyph vertical center, not a human guess at a seam. Confirms VolUp's
// already-correct center (52.15% scanned vs 52.25% in use - a fine match)
// and gives real corrected centers for the other two: VolDown 61.48%
// (was computed around 63.65%) and Prev/Next 71.08% (was ~74.03%) - both
// now sit in a clean, evenly-spaced ~9.2-9.6-point cadence alongside
// VolUp and ThumbsDown, which the earlier eyeballed values did not.
const _v2VolUp = _RemoteButtonRect(6.60, 48.75, 43.05, 7.00);
const _v2VolDown = _RemoteButtonRect(6.60, 57.98, 43.05, 7.00);
const _v2PlayPause = _RemoteButtonRect(49.65, 49.45, 43.05, 17.00);
const _v2Prev = _RemoteButtonRect(6.60, 67.58, 43.05, 7.00);
const _v2Next = _RemoteButtonRect(49.65, 67.58, 43.05, 7.00);
const _v2ThumbsDown = _RemoteButtonRect(6.60, 81.33, 43.05, 10.73);
const _v2ThumbsUp = _RemoteButtonRect(49.65, 81.33, 43.05, 10.73);

// The on-screen display graphic v2 has that v1 doesn't - calibrated the same
// grid-then-verify way as every button rect above, then pulled in further
// per direct feedback so the live text sits comfortably inside the glass
// rather than close to filling it edge to edge.
const _v2Display = _RemoteButtonRect(16, 8, 68, 7);

class _RemoteLayout {
  final String asset;
  final double aspectRatio;
  final _RemoteButtonRect power, aux, volUp, volDown, playPause, prev, next, thumbsDown, thumbsUp;
  final Map<String, _RemoteButtonRect> presets;
  final _RemoteButtonRect? display;
  // True only for remotev2 - its volUp/volDown/playPause/prev/next values
  // are already the FINAL direct target rect (see their own doc comment),
  // not a raw value meant to survive _RemoteImage._inset. remotev1's own
  // values for these five are untouched (confirmed already correct) and
  // still go through the normal shared inset like every other button.
  final bool midSectionIsFinalRect;

  const _RemoteLayout({
    required this.asset,
    required this.aspectRatio,
    required this.power,
    required this.aux,
    required this.volUp,
    required this.volDown,
    required this.playPause,
    required this.prev,
    required this.next,
    required this.thumbsDown,
    required this.thumbsUp,
    required this.presets,
    this.display,
    this.midSectionIsFinalRect = false,
  });
}

const _layouts = [
  _RemoteLayout(
    asset: 'assets/remotev1.png',
    aspectRatio: 366 / 906,
    power: _v1Power,
    aux: _v1Aux,
    volUp: _v1VolUp,
    volDown: _v1VolDown,
    playPause: _v1PlayPause,
    prev: _v1Prev,
    next: _v1Next,
    thumbsDown: _v1ThumbsDown,
    thumbsUp: _v1ThumbsUp,
    presets: _v1Presets,
  ),
  _RemoteLayout(
    asset: 'assets/remotev2.png',
    aspectRatio: 370 / 932,
    power: _v2Power,
    aux: _v2Aux,
    volUp: _v2VolUp,
    volDown: _v2VolDown,
    playPause: _v2PlayPause,
    prev: _v2Prev,
    next: _v2Next,
    thumbsDown: _v2ThumbsDown,
    thumbsUp: _v2ThumbsUp,
    presets: _v2Presets,
    display: _v2Display,
    midSectionIsFinalRect: true,
  ),
];

/// Fullscreen swipeable, INTERACTIVE virtual remote - two candidate button
/// layouts (remotev1.png/remotev2.png) with invisible tap-zones placed at
/// percentages matching each image's own real button positions, the exact
/// same "real photo + percentage hitbox overlay" technique PanelControl
/// already uses (see its own doc comment) - per the same explicit user
/// direction to match a reference image's real button positions rather than
/// approximate them with generic flat widgets.
///
/// Which speaker the remote controls is explicitly selectable up top - see
/// _speakerSelector's own doc comment for why it only actually shows when
/// there's a real choice to make. Which of the two candidate designs is
/// active is ALSO an explicit choice (a chip pair), not swipe-to-browse -
/// changed 2026-07-25 from an earlier swipeable PageView, per direct
/// feedback that "selective" (a clear, deliberate pick) reads better here
/// than an implicit gesture with just page-dots to show where you landed.
///
/// Thumbs up/down are visible but intentionally NOT wired to anything -
/// there is no existing "rate this track" concept anywhere else in the app
/// to reuse, so they're left inert rather than guessing at a mapping.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  /// Stores a PlaybackTarget.id, re-resolved against the live target list on
  /// every build (see _resolveTarget) rather than trusted directly - same
  /// convention as home_screen.dart's own _targetSessionId, for the same
  /// reason (the target this id pointed at may have disconnected since).
  String? _targetId;
  int _selectedLayout = 0;

  @override
  void initState() {
    super.initState();
    // Seeded from whichever design was last picked (persisted across app
    // restarts - see SpeakerController.setLastRemoteDesignIndex), clamped in
    // case a design was ever removed and an old saved index no longer fits.
    final saved = context.read<SpeakerController>().settings.lastRemoteDesignIndex;
    _selectedLayout = saved.clamp(0, _layouts.length - 1);
  }

  PlaybackTarget? _resolveTarget(SpeakerController controller) {
    final targets = controller.playbackTargets;
    if (targets.isEmpty) return null;
    final id = _targetId;
    if (id != null) {
      for (final t in targets) {
        if (t.id == id) return t;
      }
    }
    return targets.first;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SpeakerController>();
    final targets = controller.playbackTargets;
    final target = _resolveTarget(controller);
    final session = target?.commandTarget;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                // Shortcut to the "Open Remote by default" toggle - it lives
                // in the main Settings screen (below Stream Proxy URL/Save &
                // Continue), which direct feedback (2026-07-25) said wasn't
                // easy to find starting from here.
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white),
                  tooltip: 'Remote settings',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
                ),
              ],
            ),
            if (target != null) _speakerSelector(targets, target),
            _designSelector(),
            const SizedBox(height: 8),
            Expanded(
              child: session == null
                  ? const Center(
                      child: Text('Connect a speaker first.', style: TextStyle(color: Colors.grey)),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _layouts[_selectedLayout].aspectRatio,
                          child: _RemoteImage(session: session, layout: _layouts[_selectedLayout]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Only shown when there's more than one connected speaker/pair to choose
  /// between - with just one, that one is simply the target, no picker
  /// needed at all. Same ChoiceChip-per-target pattern as home_screen.dart's
  /// own _targetSpeakerSelector, for the same "unambiguous target, no
  /// silent guess" reason.
  Widget _speakerSelector(List<PlaybackTarget> targets, PlaybackTarget current) {
    if (targets.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final t in targets)
            ChoiceChip(
              label: Text(t.displayName),
              selected: t.id == current.id,
              onSelected: (_) => setState(() => _targetId = t.id),
            ),
        ],
      ),
    );
  }

  Widget _designSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < _layouts.length; i++)
            ChoiceChip(
              label: Text('Design ${i + 1}'),
              selected: _selectedLayout == i,
              onSelected: (_) {
                setState(() => _selectedLayout = i);
                context.read<SpeakerController>().setLastRemoteDesignIndex(i);
              },
            ),
        ],
      ),
    );
  }
}

/// The remote image itself plus every invisible tap-zone overlaid on top of
/// it, at percentages of the image's own box - same layering PanelControl
/// uses (image at the bottom of a Stack, Positioned hitboxes on top).
class _RemoteImage extends StatelessWidget {
  final SpeakerSession session;
  final _RemoteLayout layout;

  const _RemoteImage({required this.session, required this.layout});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final display = layout.display;
        return Stack(
          children: [
            Image.asset(layout.asset, fit: BoxFit.fill, width: w, height: h),
            if (display != null) _displayOverlay(display, w, h),
            _hit(
              layout.power,
              w,
              h,
              onTap: (c) => c.sendKey(session, 'POWER'),
              isOn: () => session.nowPlaying?.isOn ?? false,
            ),
            _hit(
              layout.aux,
              w,
              h,
              onTap: (c) => c.toggleAuxSource(session),
              isOn: () => session.nowPlaying?.source == 'AUX',
            ),
            _hit(layout.volUp, w, h, onTap: (c) => c.volStep(session, 5), applyInset: !layout.midSectionIsFinalRect),
            _hit(layout.volDown, w, h, onTap: (c) => c.volStep(session, -5), applyInset: !layout.midSectionIsFinalRect),
            _hit(
              layout.playPause,
              w,
              h,
              onTap: (c) {
                // Same "is this session ACTUALLY playing right now" signal
                // TransportRow uses, for the same reason - see its own doc
                // comment.
                final isPlaying = !session.manuallyPaused && session.nowPlaying?.isPlaying == true;
                c.sendKey(session, isPlaying ? 'PAUSE' : 'PLAY');
              },
              applyInset: !layout.midSectionIsFinalRect,
            ),
            _hit(layout.prev, w, h, onTap: (c) => c.transportSkip(session, -1), applyInset: !layout.midSectionIsFinalRect),
            _hit(layout.next, w, h, onTap: (c) => c.transportSkip(session, 1), applyInset: !layout.midSectionIsFinalRect),
            for (final entry in layout.presets.entries) _preset(entry.key, entry.value, w, h),
          ],
        );
      },
    );
  }

  // Shrinks a rect toward its own center by fixed percentage-points of the
  // FULL image on each side (not a fraction of the rect's own size, so the
  // margin is visually consistent across differently-sized buttons) before
  // ever converting to pixels. Calibrated coordinates were measured against
  // each button's true visible edges, but real-device testing (2026-07-25)
  // showed the raw rects reading as "the highlight overflows past the
  // button" for anyone actually tapping it - a physical remote's buttons
  // read as smaller/more separated than a flat photo of one suggests, and
  // per direct feedback an approximate-but-safely-inside zone is preferable
  // to an edge-accurate one that visibly bleeds into the surrounding bezel.
  static const double _insetX = 3;
  static const double _insetY = 2;

  _RemoteButtonRect _inset(_RemoteButtonRect r) {
    return _RemoteButtonRect(
      r.left + _insetX,
      r.top + _insetY,
      r.width - (2 * _insetX),
      r.height - (2 * _insetY),
    );
  }

  Widget _hit(
    _RemoteButtonRect rect,
    double w,
    double h, {
    required void Function(SpeakerController c) onTap,
    bool Function()? isOn,
    // False for Volume+/-/PlayPause/Prev/Next - see their call sites below
    // for why: chaining rect measurement THROUGH this shared shrink (raw
    // value -> _inset -> final) turned out to be genuinely hard to get
    // right after two rounds of live correction, each compensating for the
    // other and overshooting. Those five now pass their FINAL, direct
    // target rect and skip this entirely, rather than a raw value meant to
    // survive an extra transform.
    bool applyInset = true,
  }) {
    final r = applyInset ? _inset(rect) : rect;
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: Consumer<SpeakerController>(
        builder: (context, controller, _) {
          final on = isOn?.call() ?? false;
          return _RemoteHitBox(onTap: () => onTap(controller), color: on ? const Color(0x3822C55E) : null);
        },
      ),
    );
  }

  Widget _preset(String num, _RemoteButtonRect rect, double w, double h) {
    final r = _inset(rect);
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: r.height / 100 * h,
      child: _RemotePresetHitBox(session: session, presetNum: num),
    );
  }

  // No inset here - unlike the button hitboxes, this is a purely visual
  // overlay (nothing to tap), so it should sit as close to the true glass
  // edges as possible rather than shrink away from them.
  Widget _displayOverlay(_RemoteButtonRect r, double w, double h) {
    final boxHeight = r.height / 100 * h;
    return Positioned(
      left: r.left / 100 * w,
      top: r.top / 100 * h,
      width: r.width / 100 * w,
      height: boxHeight,
      child: _OledDisplay(session: session, boxHeight: boxHeight),
    );
  }
}

/// Live "now playing" status shown inside remotev2's on-screen display
/// graphic - title, elapsed/total time, play/pause state, and whichever
/// preset (if any) matches what's currently playing. Styled to read as an
/// actual monochrome OLED/VFD remote display (flat black background, a
/// single accent color, monospace-ish lettering) rather than a normal app
/// panel.
class _OledDisplay extends StatelessWidget {
  final SpeakerSession session;
  final double boxHeight;

  const _OledDisplay({required this.session, required this.boxHeight});

  static const _oledColor = Color(0xFF39FF6A);

  // The height this display's content (17px title + 2px gap + a ~19px icon
  // row, plus 3+3 vertical padding) was tuned to fit comfortably against -
  // fine on a tablet, where the AspectRatio-constrained remote renders large
  // enough that 7% of its height comfortably clears this. On a phone, the
  // same remote (same 7%-of-height box, same aspect ratio) renders much
  // smaller in absolute terms, so this box can come out shorter than the
  // fixed pixel sizes below need - overflowing past its own bottom edge
  // (confirmed directly via a real device screenshot, 2026-07-26). Scaling
  // every size/spacing below by boxHeight/_referenceHeight keeps content
  // proportional to whatever height this box ACTUALLY gets, so it always
  // fits: clamped at a max of 1.0 so a tablet's larger-than-reference box
  // never enlarges past the already-tuned tablet appearance (zero visual
  // change there), and shrinks below 1.0 only when the box is smaller.
  static const _referenceHeight = 52.0;

  @override
  Widget build(BuildContext context) {
    final scale = (boxHeight / _referenceHeight).clamp(0.5, 1.0);
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final title = session.speakerReachable
            ? (controller.currentPlayingTitle(session) ?? session.nowPlaying?.displayText ?? 'No signal')
            : 'Unreachable';
        final progress = session.displayProgressText;
        final isPlaying = !session.manuallyPaused && session.nowPlaying?.isPlaying == true;
        final sourceLabel = _sourceLabel(controller, session);
        String? activePreset;
        for (final num in const ['1', '2', '3', '4', '5', '6']) {
          if (session.isPresetPlaying(num)) {
            activePreset = num;
            break;
          }
        }
        final baseStyle = TextStyle(
          color: _oledColor,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          // A soft glow behind the glyphs, not a solid backing box - per
          // direct feedback (2026-07-25) the display should read as text
          // genuinely lit up on top of the photo's own screen graphic, not
          // a flat black rectangle painted over it.
          shadows: [Shadow(color: _oledColor.withValues(alpha: 0.85), blurRadius: 6)],
        );
        return Stack(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Font sizes bumped up 2026-07-25 per direct feedback
                  // (bigger text, NOT a bigger display box - the box itself
                  // was already correctly sized) - still comfortably fits
                  // the box's own height with room to spare. Play/pause and
                  // volume bumped a further notch to match the title, per a
                  // follow-up "adjust the others too" request.
                  _MarqueeText(text: title, style: baseStyle.copyWith(fontSize: 17 * scale)),
                  SizedBox(height: 2 * scale),
                  // Wrap (not Row) - so a narrow rendered size drops "PRESET
                  // N" to its own line instead of overflowing past the
                  // display glass's own right edge.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8 * scale,
                    runSpacing: 1 * scale,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isPlaying ? Icons.play_arrow : Icons.pause, color: _oledColor, size: 19 * scale),
                          SizedBox(width: 3 * scale),
                          Text(progress ?? '--:--', style: baseStyle.copyWith(fontSize: 17 * scale)),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.volume_up, color: _oledColor, size: 19 * scale),
                          SizedBox(width: 3 * scale),
                          Text('${session.displayVolume}', style: baseStyle.copyWith(fontSize: 17 * scale)),
                        ],
                      ),
                      if (activePreset != null)
                        Text('PRESET $activePreset', style: baseStyle.copyWith(fontSize: 17 * scale)),
                      if (sourceLabel != null) Text(sourceLabel, style: baseStyle.copyWith(fontSize: 17 * scale)),
                    ],
                  ),
                ],
              ),
            ),
            // Purely decorative - floating notes in whatever free space is
            // left, only while something is actually playing. Added per
            // direct request ("mag-add sa free space ng screen ng
            // animation na mga note kapag nag-pplay na ang music"). Vertically
            // CENTERED on the whole display box (not pinned to the top) -
            // pinning it to the top put it right in the marquee title's own
            // path, which sweeps the full width whenever the title is long
            // enough to scroll, per direct follow-up feedback.
            if (isPlaying)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: _PlayingNotes(color: _oledColor),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Which of the app's sources is currently playing, if any - same "TuneIn"
  /// label home_screen.dart's own player-card source indicator uses
  /// (_sourceLabel there), PLUS Spotify/AUX/Bluetooth, which that indicator
  /// deliberately doesn't cover (it only tracks the app's own search-result
  /// sources) but which the device itself reports directly via
  /// NowPlaying.source. Null when neither check resolves to anything (a
  /// plain preset with no matching search result, standby, etc.) - the Wrap
  /// above just omits this chip in that case.
  String? _sourceLabel(SpeakerController controller, SpeakerSession session) {
    if (controller.isPlayingRadio(session)) return 'TuneIn';
    switch (session.nowPlaying?.source) {
      case 'SPOTIFY':
        return 'Spotify';
      case 'AUX':
        return 'AUX';
      case 'BLUETOOTH':
        return 'Bluetooth';
      default:
        return null;
    }
  }
}

/// A few music-note glyphs that drift upward and fade, looping - shown only
/// while [_OledDisplay] has something actually playing. Purely decorative,
/// deliberately small and confined to a corner so it never competes with
/// the actual now-playing text for attention.
class _PlayingNotes extends StatefulWidget {
  final Color color;

  const _PlayingNotes({required this.color});

  @override
  State<_PlayingNotes> createState() => _PlayingNotesState();
}

class _PlayingNotesState extends State<_PlayingNotes> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            clipBehavior: Clip.none,
            children: [for (var i = 0; i < 3; i++) _note(i)],
          );
        },
      ),
    );
  }

  Widget _note(int i) {
    // Each note runs the same 0..1 cycle, just started at its own staggered
    // phase, so they drift upward one after another rather than in lockstep.
    final t = (_controller.value + i / 3) % 1.0;
    final dy = 18 - t * 20;
    final fadeIn = (t / 0.2).clamp(0.0, 1.0);
    final fadeOut = ((1 - t) / 0.3).clamp(0.0, 1.0);
    final opacity = fadeIn < fadeOut ? fadeIn : fadeOut;
    return Positioned(
      left: (i * 9).toDouble(),
      top: dy,
      child: Opacity(
        opacity: opacity,
        child: Icon(Icons.music_note, color: widget.color, size: 11),
      ),
    );
  }
}

/// Scrolls [text] right-to-left ONLY when it's too wide to fit - starts at
/// its natural, fully-left-aligned reading position (never pre-scrolled),
/// slides left just far enough to bring the cut-off tail into view (the
/// text's own right edge stops flush with the box's right edge, never
/// scrolling past that), holds there briefly, then jumps back to the start
/// and repeats. A single Text instance clipped by the box - deliberately
/// NOT the two-copies-chasing-each-other style marquee some tickers use;
/// per direct feedback this should still read as one normal, single-line
/// screen that just happens to slide, clipped the same way at both edges,
/// not an infinite scroll that overlaps itself.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  Animation<double>? _offset;
  String? _configuredFor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _configure(double boxWidth) {
    final key = '${widget.text}|$boxWidth';
    if (_configuredFor == key) return;
    _configuredFor = key;

    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final overflow = painter.width - boxWidth;

    _controller.stop();
    if (overflow <= 0) {
      _offset = null;
      return;
    }

    // ~35 logical px/s - a comfortable reading pace, clamped so a barely-
    // overflowing title isn't a blink and a very long one doesn't take
    // forever to finish one pass.
    const holdMs = 1200;
    final scrollMs = (overflow / 35 * 1000).clamp(1500, 20000).round();
    _controller.duration = Duration(milliseconds: holdMs + scrollMs + holdMs);
    _offset = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: holdMs.toDouble()),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -overflow), weight: scrollMs.toDouble()),
      TweenSequenceItem(tween: ConstantTween(-overflow), weight: holdMs.toDouble()),
    ]).animate(_controller);
    _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _configure(constraints.maxWidth);
        final offset = _offset;
        return ClipRect(
          child: offset == null
              ? Text(widget.text, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: widget.style)
              : AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) => Align(
                    alignment: Alignment.centerLeft,
                    child: Transform.translate(
                      offset: Offset(offset.value, 0),
                      child: Text(widget.text, maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: widget.style),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _RemoteHitBox extends StatefulWidget {
  final VoidCallback onTap;
  final Color? color;

  const _RemoteHitBox({required this.onTap, this.color});

  @override
  State<_RemoteHitBox> createState() => _RemoteHitBoxState();
}

class _RemoteHitBoxState extends State<_RemoteHitBox> with SingleTickerProviderStateMixin {
  bool _pressed = false;
  // A bright, distinct white flash on every confirmed tap - separate from
  // both the momentary _pressed overlay (only visible while a finger is
  // literally still down, easy to miss on a fast tap) and the persistent
  // isOn/isPlaying green tint this same Container also shows (similar
  // enough in color to the press overlay that direct feedback (2026-07-25)
  // called out having no clear way to tell "I just tapped this" apart from
  // "this happens to be the active one". forward-then-reverse gives a
  // deliberate ~440ms pulse regardless of how brief the actual tap was.
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _flash.forward(from: 0).then((_) {
      if (mounted) _flash.reverse();
    });
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _flash,
        builder: (context, _) {
          final base = _pressed ? const Color(0x5922C55E) : (widget.color ?? Colors.transparent);
          return Container(color: Color.alphaBlend(Colors.white.withValues(alpha: 0.55 * _flash.value), base));
        },
      ),
    );
  }
}

/// Preset gesture: tap-to-play only - see PanelControl's own _PresetHitBox
/// doc comment for why the former hold-to-save gesture was removed
/// (real-hardware testing showed it never reliably reached the same
/// persistent store a genuine physical hold does). A long-press here still
/// shows a hint pointing at the physical button instead of doing nothing.
class _RemotePresetHitBox extends StatefulWidget {
  final SpeakerSession session;
  final String presetNum;

  const _RemotePresetHitBox({required this.session, required this.presetNum});

  @override
  State<_RemotePresetHitBox> createState() => _RemotePresetHitBoxState();
}

class _RemotePresetHitBoxState extends State<_RemotePresetHitBox> with SingleTickerProviderStateMixin {
  Timer? _holdTimer;
  bool _didLongPress = false;
  bool _pressed = false;
  // Same distinct white tap-flash as _RemoteHitBox, for the same reason -
  // only fired on a confirmed tap-to-play, not on the long-press-hint path.
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

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
      HapticFeedback.lightImpact();
      _flash.forward(from: 0).then((_) {
        if (mounted) _flash.reverse();
      });
      context.read<SpeakerController>().playPreset(widget.session, widget.presetNum);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeakerController>(
      builder: (context, controller, _) {
        final playing = widget.session.isPresetPlaying(widget.presetNum);
        Color base;
        if (playing) {
          base = const Color(0x2222C55E);
        } else if (_pressed) {
          base = const Color(0x5922C55E);
        } else {
          base = Colors.transparent;
        }
        return GestureDetector(
          onTapDown: (_) => _start(),
          onTapUp: (_) => _cancel(),
          onTapCancel: () => _cancel(triggerPlay: false),
          child: AnimatedBuilder(
            animation: _flash,
            builder: (context, _) {
              return Container(color: Color.alphaBlend(Colors.white.withValues(alpha: 0.55 * _flash.value), base));
            },
          ),
        );
      },
    );
  }
}
