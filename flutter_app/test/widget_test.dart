import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soundtouch_control/main.dart';

void main() {
  testWidgets('App boots to onboarding without crashing', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SoundTouchApp());
    await tester.pump();
    expect(find.text('Search Server URL'), findsOneWidget);
  });
}
