import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:soundtech_air/models/speaker_info.dart';
import 'package:soundtech_air/state/speaker_controller.dart';
import 'package:soundtech_air/widgets/panel_control.dart';

/// PanelControl is now an invisible-overlay hitbox layout on top of a real
/// photo (assets/panel.png) - there's no Text('Power')/Icon(volume_up) to
/// find anymore, since the button graphics are baked into the image. So the
/// thing actually worth regression-testing is exactly what could silently
/// break here: the hand-calibrated percentage rects landing at sane,
/// distinct, non-overlapping positions - not "no overflow exception".
///
/// Deliberately does NOT drive a real tap-to-network round trip (that would
/// need real dart:io sockets to resolve inside testWidgets()'s FakeAsync-ish
/// binding, which they don't reliably do - see fake_speaker_server_test.dart
/// and transport_skip_test.dart for that coverage instead, using plain
/// test() against the exact same controller methods these hitboxes call).
/// Geometry is the one thing unique to THIS widget, so that's what's checked
/// directly via each hitbox's own Key.
void main() {
  const panelWidth = 452.0; // matches home_screen.dart's card content width

  Future<SpeakerSession> pumpPanel(WidgetTester tester, {double width = panelWidth}) async {
    final controller = SpeakerController();
    final session = SpeakerSession(SpeakerInfo(ip: '127.0.0.1', deviceId: 'test', name: 'Test Speaker'));
    controller.sessions = [session];

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<SpeakerController>.value(
          value: controller,
          child: Scaffold(
            body: SizedBox(width: width, child: PanelControl(session: session)),
          ),
        ),
      ),
    );
    await tester.pump();
    return session;
  }

  const hitboxKeys = [
    'power-hitbox',
    'aux-hitbox',
    'volup-hitbox',
    'voldown-hitbox',
    'preset-hitbox-1',
    'preset-hitbox-2',
    'preset-hitbox-3',
    'preset-hitbox-4',
    'preset-hitbox-5',
    'preset-hitbox-6',
  ];

  testWidgets('renders the reference photo without overflow at a realistic card width', (tester) async {
    await pumpPanel(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('still lays out cleanly at a narrower phone width', (tester) async {
    await pumpPanel(tester, width: 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out cleanly inside a SingleChildScrollView, like the real per-speaker card', (tester) async {
    // home_screen.dart's actual embedding: SingleChildScrollView -> Column ->
    // ... -> PanelControl, not a directly-bounded Scaffold.body.
    final controller = SpeakerController();
    final session = SpeakerSession(SpeakerInfo(ip: '127.0.0.1', deviceId: 'test', name: 'Test Speaker'));
    controller.sessions = [session];

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<SpeakerController>.value(
          value: controller,
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: panelWidth,
                child: Column(children: [PanelControl(session: session)]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('all 10 hitboxes are present, non-empty, and stay fully inside the panel', (tester) async {
    await pumpPanel(tester);
    final panelRect = tester.getRect(find.byType(PanelControl));

    for (final key in hitboxKeys) {
      final finder = find.byKey(ValueKey(key));
      expect(finder, findsOneWidget, reason: '$key should exist');
      final rect = tester.getRect(finder);
      expect(rect.width, greaterThan(0), reason: '$key should have non-zero width');
      expect(rect.height, greaterThan(0), reason: '$key should have non-zero height');
      expect(panelRect.contains(rect.topLeft), true, reason: '$key top-left should be inside the panel image');
      expect(panelRect.contains(rect.bottomRight), true, reason: '$key bottom-right should be inside the panel image');
    }
  });

  testWidgets('no two hitboxes overlap each other', (tester) async {
    await pumpPanel(tester);
    final rects = {for (final key in hitboxKeys) key: tester.getRect(find.byKey(ValueKey(key)))};

    for (final a in hitboxKeys) {
      for (final b in hitboxKeys) {
        if (a == b) continue;
        final overlap = rects[a]!.intersect(rects[b]!);
        expect(
          overlap.width <= 0 || overlap.height <= 0,
          true,
          reason: '$a and $b should not overlap, got $overlap',
        );
      }
    }
  });

  testWidgets('the preset grid reads left-to-right, top-to-bottom (1..6) matching the photo', (tester) async {
    await pumpPanel(tester);
    final r1 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-1')));
    final r2 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-2')));
    final r3 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-3')));
    final r4 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-4')));
    final r5 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-5')));
    final r6 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-6')));

    expect(r1.left, lessThan(r2.left));
    expect(r2.left, lessThan(r3.left));
    expect(r4.left, lessThan(r5.left));
    expect(r5.left, lessThan(r6.left));
    expect(r1.top, lessThan(r4.top));
    expect(r2.top, lessThan(r5.top));
    expect(r3.top, lessThan(r6.top));
  });

  testWidgets('Power/Aux sit in the left margin and Vol+/Vol- sit in the right margin, matching the photo', (tester) async {
    await pumpPanel(tester);
    final panelRect = tester.getRect(find.byType(PanelControl));
    final power = tester.getRect(find.byKey(const ValueKey('power-hitbox')));
    final aux = tester.getRect(find.byKey(const ValueKey('aux-hitbox')));
    final volUp = tester.getRect(find.byKey(const ValueKey('volup-hitbox')));
    final volDown = tester.getRect(find.byKey(const ValueKey('voldown-hitbox')));
    final preset1 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-1')));
    final preset3 = tester.getRect(find.byKey(const ValueKey('preset-hitbox-3')));

    expect(power.left, lessThan(preset1.left));
    expect(aux.left, lessThan(preset1.left));
    expect(power.top, lessThan(aux.top));
    expect(volUp.left, greaterThan(preset3.right));
    expect(volDown.left, greaterThan(preset3.right));
    expect(volUp.top, lessThan(volDown.top));
    expect(power.left, greaterThanOrEqualTo(panelRect.left));
    expect(volUp.right, lessThanOrEqualTo(panelRect.right));
  });

  testWidgets('tapping each hitbox does not throw', (tester) async {
    // Confirms the gesture pipeline reaches every hitbox without crashing -
    // NOT that the resulting network call resolves (see the file doc
    // comment for why that's tested elsewhere instead).
    await pumpPanel(tester);
    for (final key in hitboxKeys) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'tapping $key should not throw');
    }
  });
}
