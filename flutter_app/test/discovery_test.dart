import 'package:flutter_test/flutter_test.dart';
import 'package:soundtech_air/services/discovery.dart';

void main() {
  group('isSetupModeSubnet', () {
    test('the speaker setup AP\'s own fixed gateway is recognized', () {
      expect(isSetupModeSubnet('192.0.2.1'), isTrue);
    });

    test('any other address in the same /24 is recognized too', () {
      expect(isSetupModeSubnet('192.0.2.254'), isTrue);
    });

    test('a real home router subnet is not mistaken for it', () {
      expect(isSetupModeSubnet('192.168.1.42'), isFalse);
      expect(isSetupModeSubnet('10.0.0.15'), isFalse);
      expect(isSetupModeSubnet('192.0.3.1'), isFalse);
    });
  });
}
