import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soundtech_air/main.dart';
import 'package:soundtech_air/state/speaker_controller.dart';

void main() {
  testWidgets('A fresh install boots straight to speaker setup, not the old onboarding screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(SoundTouchApp(speakerController: SpeakerController()));
    await tester.pump();
    expect(find.text('Speakers'), findsOneWidget);
    expect(find.text('Setup New Speaker'), findsOneWidget);
    // The old onboarding step (confirm Stream Proxy URL / "Test Search
    // Server") no longer exists at all - removed 2026-07-25 per direct
    // feedback that a brand-new install should land on speaker scan/setup
    // immediately instead.
    expect(find.text('Search Server'), findsNothing);
  });
}
