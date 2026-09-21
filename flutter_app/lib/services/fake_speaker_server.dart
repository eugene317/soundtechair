import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// Dev/debug-only in-process fake SoundTouch device. Binds real HTTP
/// listeners on a loopback address (127.0.0.x - never reachable off this
/// device, never touching any real network) and answers the same endpoints
/// XmlApiClient/SoapClient call for a real speaker, so a dummy/preview
/// speaker exercises the REAL network code paths (same HTTP client, same
/// XML parsing) instead of a special-cased shortcut elsewhere in the app.
/// Entirely self-contained - deleting this file and its handful of call
/// sites in SpeakerController (search for FakeSpeakerServer) removes the
/// feature completely; nothing about real-speaker communication changes.
class FakeSpeakerServer {
  final String ip;
  final String deviceId;
  final String name;

  FakeSpeakerServer({required this.ip, required this.deviceId, required this.name});

  HttpServer? _xmlServer;
  HttpServer? _soapServer;
  HttpServer? _wsServer;
  final Set<WebSocket> _wsClients = {};

  // --- simulated device state ---
  String? _source; // null/'INVALID_SOURCE' = standby, else e.g. 'AUX', 'INTERNET_RADIO'
  String? _location;
  String? _track;
  String? _stationName;
  bool _isPlaying = false;
  DateTime? _playStartedAt;
  int _elapsedAtPlayStart = 0;
  int? _totalSeconds;
  int _volume = 30;
  final Map<String, String?> _presets = {};
  final Map<String, DateTime> _keyPressedAt = {};

  // Pairing ("group") state - mirrored across both paired fake devices via
  // the shared registry below, the same way a real pair's two independent
  // firmwares would each answer /group consistently.
  String _groupId = '';
  String? _groupName;
  String? _groupMasterDeviceId;
  String? _groupRolesXml;

  static final Map<String, FakeSpeakerServer> _registry = {};

  /// Registers itself (and is discoverable as a pairing partner) only once
  /// BOTH ports are bound. If the second bind fails after the first
  /// succeeds, closes what was opened and stays out of the registry, so a
  /// failed connect attempt (e.g. a stale listener from a previous hot
  /// restart still holding the port) can't leak a socket that nothing can
  /// ever reach again to stop.
  Future<void> start() async {
    final addr = InternetAddress(ip);
    try {
      _xmlServer = await HttpServer.bind(addr, 8090);
      // Disables HttpServer's own internal idle-connection Timer, which has
      // no value on a loopback-only dev/test fixture anyway - and, left on,
      // trips flutter_test's "Timer still pending after dispose" invariant
      // check in any testWidgets() test that starts one of these (widget
      // tests run inside a FakeAsync-based binding that plain test() cases
      // driving this same server never touch, which is why this only
      // surfaces there).
      _xmlServer!.idleTimeout = null;
      _xmlServer!.listen(_handleXml, onError: (_) {});
      _soapServer = await HttpServer.bind(addr, 8091);
      _soapServer!.idleTimeout = null;
      _soapServer!.listen(_handleSoap, onError: (_) {});
      _wsServer = await HttpServer.bind(addr, 8080);
      _wsServer!.idleTimeout = null;
      _wsServer!.listen(_handleWsUpgrade, onError: (_) {});
      _registry[deviceId] = this;
    } catch (e) {
      await _xmlServer?.close(force: true);
      await _soapServer?.close(force: true);
      _xmlServer = null;
      _soapServer = null;
      _wsServer = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    _registry.remove(deviceId);
    for (final ws in _wsClients.toList()) {
      await ws.close();
    }
    _wsClients.clear();
    await _xmlServer?.close(force: true);
    await _soapServer?.close(force: true);
    await _wsServer?.close(force: true);
  }

  /// Test hook simulating a PHYSICAL preset-button press: pushes the same
  /// nowSelectionUpdated notification shape a real SoundTouch's own
  /// notification WebSocket sends, to every currently-connected client (the
  /// same real endpoint PresetButtonRelayService listens on).
  Future<void> simulatePresetButtonPress(String presetId, {required String location}) async {
    final message = '<updates deviceID="$deviceId">'
        '<nowSelectionUpdated deviceID="$deviceId">'
        '<preset id="$presetId">'
        '<ContentItem source="INTERNET_RADIO" location="${_xmlEscape(location)}" />'
        '</preset>'
        '</nowSelectionUpdated>'
        '</updates>';
    for (final ws in _wsClients.toList()) {
      ws.add(message);
    }
  }

  Future<void> _handleWsUpgrade(HttpRequest request) async {
    try {
      final ws = await WebSocketTransformer.upgrade(request, protocolSelector: (protocols) => 'gabbo');
      _wsClients.add(ws);
      ws.listen(
        (_) {},
        onDone: () => _wsClients.remove(ws),
        onError: (_) => _wsClients.remove(ws),
        cancelOnError: true,
      );
    } catch (_) {
      // Not a WebSocket upgrade request, or the upgrade failed - nothing to do.
    }
  }

  int get _currentElapsed {
    if (!_isPlaying || _playStartedAt == null) return _elapsedAtPlayStart;
    return _elapsedAtPlayStart + DateTime.now().difference(_playStartedAt!).inSeconds;
  }

  Future<void> _respond(HttpRequest request, String xmlBody, {int statusCode = 200}) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    request.response.write(xmlBody);
    await request.response.close();
  }

  Future<void> _handleXml(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final method = request.method;
      final body = method == 'POST' ? await utf8.decoder.bind(request).join() : '';
      switch (path) {
        case '/info':
          await _respond(request, _infoXml());
        case '/now_playing':
          await _respond(request, _nowPlayingXml());
        case '/volume':
          if (method == 'POST') {
            _volume = _volumeFromRequestBody(body) ?? _volume;
            await _respond(request, '<volume/>');
          } else {
            await _respond(request, _volumeXml());
          }
        case '/presets':
          await _respond(request, _presetsXml());
        case '/key':
          _handleKey(body);
          await _respond(request, '<status>/key</status>');
        case '/select':
          _handleSelect(body);
          await _respond(request, '<status>/select</status>');
        case '/getGroup':
          await _respond(request, _groupXml());
        case '/addGroup':
          _handleAddGroup(body);
          await _respond(request, _groupXml());
        case '/removeGroup':
          _handleRemoveGroup();
          await _respond(request, '<group/>');
        default:
          await _respond(request, '<error>not found</error>', statusCode: 404);
      }
    } catch (_) {
      try {
        await _respond(request, '<error>fake speaker error</error>', statusCode: 500);
      } catch (_) {
        // Response already closed/errored - nothing more to do.
      }
    }
  }

  Future<void> _handleSoap(HttpRequest request) async {
    try {
      final action = request.headers.value('SOAPACTION') ?? '';
      final body = await utf8.decoder.bind(request).join();
      if (action.contains('SetAVTransportURI')) {
        _handleSetAvTransportUri(body);
      } else if (action.contains('#Play')) {
        _isPlaying = true;
        _playStartedAt = DateTime.now();
      } else if (action.contains('#Stop')) {
        _elapsedAtPlayStart = _currentElapsed;
        _isPlaying = false;
        _playStartedAt = null;
      }
      await _respond(request, '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body/></s:Envelope>');
    } catch (_) {
      try {
        await _respond(
          request,
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
          '<s:Fault><faultcode>Client</faultcode><faultstring>UPnPError</faultstring>'
          '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>402</errorCode><errorDescription>Invalid Args</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
          statusCode: 500,
        );
      } catch (_) {}
    }
  }

  // --- command handlers ---

  void _handleSetAvTransportUri(String soapBody) {
    final doc = XmlDocument.parse(soapBody);
    final uri = doc.findAllElements('CurrentURI').firstOrNull?.innerText;
    // CurrentURIMetaData's innerText is the DIDL-Lite XML with exactly one
    // level of escaping already undone by the outer parse above - it must
    // be parsed as its OWN XmlDocument (not regex-matched) so entities like
    // &amp; inside a real title (very common - apostrophes, "&", quotes)
    // get decoded that second time too, instead of coming out still-escaped.
    final metadataRaw = doc.findAllElements('CurrentURIMetaData').firstOrNull?.innerText ?? '';
    String? title;
    int? totalFromDuration;
    if (metadataRaw.isNotEmpty) {
      try {
        final metaDoc = XmlDocument.parse(metadataRaw);
        title = metaDoc.findAllElements('dc:title').firstOrNull?.innerText;
        final resEl = metaDoc.findAllElements('res').firstOrNull;
        totalFromDuration = _parseUpnpDuration(resEl?.getAttribute('duration'));
      } catch (_) {
        // Malformed metadata - leave title/duration unknown rather than crash.
      }
    }
    _location = uri;
    _track = title;
    _stationName = title == null ? 'Custom Station' : null;
    _totalSeconds = totalFromDuration;
    _source = 'INTERNET_RADIO';
    _elapsedAtPlayStart = 0;
    _playStartedAt = null;
    _isPlaying = false; // Real device: Play is a separate follow-up SOAP call.
  }

  int? _parseUpnpDuration(String? attr) {
    if (attr == null) return null;
    final parts = attr.split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2].split('.').first) ?? 0;
    return h * 3600 + m * 60 + s;
  }

  /// Tap (short press+release) plays/toggles; a long hold (>=2s, matching
  /// XmlApiClient.saveToPreset's real 3s hold) on a PRESET_n key saves the
  /// currently-playing location into that slot instead - same distinction a
  /// real device makes.
  void _handleKey(String body) {
    final doc = XmlDocument.parse(body);
    final root = doc.rootElement;
    final state = root.getAttribute('state');
    final key = root.innerText;
    if (state == 'press') {
      _keyPressedAt[key] = DateTime.now();
      return;
    }
    if (state != 'release') return;
    final pressedAt = _keyPressedAt.remove(key);
    final heldMs = pressedAt == null ? 0 : DateTime.now().difference(pressedAt).inMilliseconds;

    if (key.startsWith('PRESET_')) {
      final num = key.substring('PRESET_'.length);
      if (heldMs >= 2000) {
        _presets[num] = _location;
      } else {
        final loc = _presets[num];
        if (loc != null) {
          _location = loc;
          _source = 'INTERNET_RADIO';
          _stationName = 'Preset $num';
          _track = null;
          _totalSeconds = null;
          _isPlaying = true;
          _playStartedAt = DateTime.now();
          _elapsedAtPlayStart = 0;
        }
      }
      return;
    }

    switch (key) {
      case 'PLAY':
        _isPlaying = true;
        _playStartedAt = DateTime.now();
      case 'PAUSE':
        _elapsedAtPlayStart = _currentElapsed;
        _isPlaying = false;
        _playStartedAt = null;
      case 'POWER':
        if (_source == null) {
          _source = 'AUX';
          _isPlaying = false;
        } else {
          _source = null;
          _location = null;
          _track = null;
          _stationName = null;
          _isPlaying = false;
          _playStartedAt = null;
        }
    }
  }

  void _handleSelect(String body) {
    final doc = XmlDocument.parse(body);
    final source = doc.rootElement.getAttribute('source') ?? 'AUX';
    _source = source;
    _location = null;
    _track = null;
    _stationName = null;
    _totalSeconds = null;
    _isPlaying = true;
    _playStartedAt = DateTime.now();
    _elapsedAtPlayStart = 0;
  }

  int? _volumeFromRequestBody(String body) {
    try {
      final doc = XmlDocument.parse(body);
      return int.tryParse(doc.rootElement.innerText);
    } catch (_) {
      return null;
    }
  }

  void _handleAddGroup(String body) {
    final doc = XmlDocument.parse(body);
    final master = doc.findAllElements('masterDeviceId').firstOrNull?.innerText ?? deviceId;
    final name = doc.findAllElements('name').firstOrNull?.innerText ?? '';
    final rolesEl = doc.findAllElements('roles').firstOrNull;
    final rolesXml = rolesEl?.toXmlString() ?? '<roles/>';
    final memberIds = doc.findAllElements('deviceId').map((e) => e.innerText).toList();
    final groupId = '${DateTime.now().millisecondsSinceEpoch}';

    for (final id in memberIds) {
      final peer = _registry[id];
      if (peer == null) continue;
      peer._groupId = groupId;
      peer._groupName = name;
      peer._groupMasterDeviceId = master;
      peer._groupRolesXml = rolesXml;
    }
  }

  void _handleRemoveGroup() {
    final currentRoles = _groupRolesXml;
    final memberIds = currentRoles == null
        ? <String>[]
        : RegExp(r'<deviceId>([^<]+)</deviceId>').allMatches(currentRoles).map((m) => m.group(1)!).toList();
    for (final id in memberIds) {
      final peer = _registry[id];
      peer?._groupId = '';
      peer?._groupName = null;
      peer?._groupMasterDeviceId = null;
      peer?._groupRolesXml = null;
    }
    _groupId = '';
    _groupName = null;
    _groupMasterDeviceId = null;
    _groupRolesXml = null;
  }

  // --- response XML builders (schemas matched against the real parsers in
  // lib/models/*.dart and lib/services/xml_api_client.dart) ---

  String _infoXml() => '<info deviceID="$deviceId"><name>${_xmlEscape(name)}</name><type>SoundTouch 10</type></info>';

  String _nowPlayingXml() {
    final src = _source ?? 'INVALID_SOURCE';
    final locationAttr = _location != null ? ' location="${_xmlEscape(_location!)}"' : '';
    final trackXml = _track != null ? '<track>${_xmlEscape(_track!)}</track>' : '';
    final stationXml = _stationName != null ? '<stationName>${_xmlEscape(_stationName!)}</stationName>' : '';
    final playStatus = _isPlaying ? 'PLAY_STATE' : 'PAUSE_STATE';
    return '<nowPlayingInfo deviceID="$deviceId">'
        '<ContentItem source="$src"$locationAttr />'
        '$trackXml$stationXml'
        '<playStatus>$playStatus</playStatus>'
        '<time total="${_totalSeconds ?? 0}">$_currentElapsed</time>'
        '</nowPlayingInfo>';
  }

  String _volumeXml() => '<volume deviceID="$deviceId"><actualvolume>$_volume</actualvolume><targetvolume>$_volume</targetvolume></volume>';

  String _presetsXml() {
    final items = _presets.entries.where((e) => e.value != null).map((e) =>
        '<preset id="${e.key}"><ContentItem source="INTERNET_RADIO" location="${_xmlEscape(e.value!)}" /></preset>');
    return '<presets>${items.join()}</presets>';
  }

  String _groupXml() {
    final roles = _groupRolesXml;
    if (roles == null || _groupMasterDeviceId == null) return '<group/>';
    return '<group id="$_groupId"><name>${_xmlEscape(_groupName ?? '')}</name>'
        '<masterDeviceId>$_groupMasterDeviceId</masterDeviceId>$roles</group>';
  }

  static String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
