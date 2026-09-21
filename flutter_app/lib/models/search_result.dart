/// The relay-server's search endpoints return either a JSON array of results,
/// or (when there's exactly one match) a single bare JSON object - PowerShell's
/// ConvertTo-Json collapses 1-element arrays. Callers must normalize via
/// [normalizeJsonList] before mapping to typed results.
List<dynamic> normalizeJsonList(dynamic decoded) {
  if (decoded == null) return const [];
  if (decoded is List) return decoded;
  if (decoded is Map) return [decoded];
  return const [];
}

class RadioResult {
  final String name;
  final String id;
  final String? image;

  const RadioResult({required this.name, required this.id, this.image});

  factory RadioResult.fromJson(Map<String, dynamic> json) => RadioResult(
        name: json['name'] as String? ?? '',
        id: json['id'] as String? ?? '',
        image: json['image'] as String?,
      );

  Map<String, dynamic> toJson() => {'name': name, 'id': id, 'image': image};
}
