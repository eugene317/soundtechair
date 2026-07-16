/// Pure IPv4 subnet math, ported from Find-SoundTouchSpeaker's bit-twiddling
/// (SoundTouch-Common.ps1). Kept dependency-free/testable in isolation.
class SubnetMath {
  static int ipStringToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  static String intToIpString(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ].join('.');
  }

  static int maskForPrefix(int prefixLength) {
    if (prefixLength <= 0) return 0;
    if (prefixLength >= 32) return 0xFFFFFFFF;
    return (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
  }

  /// Host offsets 1..hostCount from the network base address, capped at 1022
  /// (same cap as the PowerShell original) so even a misdetected /8 doesn't
  /// trigger an absurd scan.
  static List<String> hostAddresses(String localIp, int prefixLength) {
    final ipInt = ipStringToInt(localIp);
    final maskInt = maskForPrefix(prefixLength);
    final networkInt = ipInt & maskInt;
    final rawHostCount = prefixLength >= 31 ? 0 : (1 << (32 - prefixLength)) - 2;
    final hostCount = rawHostCount > 1022 ? 1022 : rawHostCount;
    return List.generate(hostCount, (i) => intToIpString(networkInt + i + 1));
  }
}
