class SpeakerInfo {
  final String ip;
  final String deviceId;
  final String name;

  const SpeakerInfo({required this.ip, required this.deviceId, required this.name});

  factory SpeakerInfo.fromJson(Map<String, dynamic> json) => SpeakerInfo(
        ip: json['ip'] as String,
        deviceId: json['deviceId'] as String? ?? '',
        name: json['name'] as String? ?? 'Unnamed Speaker',
      );

  Map<String, dynamic> toJson() => {'ip': ip, 'deviceId': deviceId, 'name': name};
}
