import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/search_result.dart';

/// Calls relay-server.ps1's unauthenticated /api/yt_search and /api/radio_search
/// routes. No X-Pairing-Code needed (confirmed unauthenticated in the server code).
/// Responses may not be JSON at all on error (plain-text "ERROR: ..." bodies, or
/// a plain-text 503 if the server admin has stopped it), so callers get a plain
/// Exception with the raw body on any non-200 or decode failure.
class SearchApiClient {
  static const _timeout = Duration(seconds: 15);

  static Future<List<YoutubeResult>> searchYoutube(String serverUrl, String query) async {
    final list = await _searchRaw(serverUrl, '/api/yt_search', query);
    return list.map((e) => YoutubeResult.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<List<RadioResult>> searchRadio(String serverUrl, String query) async {
    final list = await _searchRaw(serverUrl, '/api/radio_search', query);
    return list.map((e) => RadioResult.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<List<dynamic>> _searchRaw(String serverUrl, String path, String query) async {
    final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
    final uri = Uri.parse('$base$path?q=${Uri.encodeQueryComponent(query)}');
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Search failed (HTTP ${response.statusCode}): ${response.body}');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Exception('Search server returned a non-JSON response: ${response.body}');
    }
    return normalizeJsonList(decoded);
  }
}
