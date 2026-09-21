import 'dart:async';

import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../services/bose_wifi_setup_service.dart';
import '../services/discovery.dart' show isSetupModeSubnet;
import '../state/speaker_controller.dart';
import '../widgets/searching_overlay.dart';

enum _Step { instructions, checking, form, submitting, done, error }

/// New/factory-reset speaker WiFi setup wizard.
///
/// Step 1 (connecting to the speaker's own temporary setup AP) is
/// deliberately MANUAL - the user connects via their phone's normal WiFi
/// Settings, same as the original Bose flow. An automatic version of this
/// step (WifiNetworkSpecifier + ConnectivityManager.requestNetwork, matching
/// the official Bose app's own approach - confirmed by decompiling its APK,
/// 2026-07-22) was tried and reverted: even after fixing a genuine missing-
/// permission bug (CHANGE_NETWORK_STATE), the automatic connect still failed
/// unreliably against a real speaker in the field (2026-07-22) - manual is
/// what's actually known to work, so that's what ships. See
/// lib/services/wifi_control_service.dart's git history if that automatic
/// path is ever worth revisiting.
///
/// Step 2/3 (picking the home network + sending credentials) still uses the
/// speaker's own WebSocket setup protocol (BoseWifiSetupService) - the same
/// protocol the official app uses - which gets a real, speaker-confirmed
/// "connected" push message instead of guessing from a timeout. That part
/// was never reported as broken, only the automatic-connect step was.
class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({super.key});

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  _Step _step = _Step.instructions;
  String _error = '';
  String _statusMessage = '';

  String? _deviceId;

  final _ssidCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isOpenNetwork = false;
  bool _obscurePassword = true;

  bool _scanLoading = false;
  String? _scanError;
  List<WiFiAccessPoint> _networks = [];
  String? _selectedSsid;
  bool _manualEntry = false;

  // Gates _doneStep(): true from the moment the speaker confirms it joined
  // the home network until THIS PHONE's own WiFi has actually left the
  // speaker's temporary setup AP (192.0.2.0/24 - see isSetupModeSubnet).
  // Before this existed, "Find the Speaker" was tappable immediately, and a
  // user tapping it before their phone finished switching back (which can
  // take several seconds - Android doesn't drop a "no internet" AP the
  // instant a better network is available) sent them into a scan that could
  // only fail or stall, with no indication why. Confirmed as a real
  // reported point of confusion, 2026-07-25.
  bool _waitingForHomeWifi = true;
  Timer? _homeWifiCheckTimer;
  final _networkInfo = NetworkInfo();

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    _homeWifiCheckTimer?.cancel();
    super.dispose();
  }

  void _watchForHomeWifi() {
    _waitingForHomeWifi = true;
    _homeWifiCheckTimer?.cancel();
    _homeWifiCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      String? ip;
      try {
        ip = await _networkInfo.getWifiIP();
      } catch (_) {
        ip = null;
      }
      // A null IP is treated as "still switching over," same as still being
      // on the setup subnet - not as "done" - since network_info_plus can
      // briefly report nothing at all mid-handoff, and a false "ready" here
      // would just recreate the exact premature-tap problem this exists to
      // prevent.
      final stillOnSetupAp = ip == null || isSetupModeSubnet(ip);
      if (!mounted || stillOnSetupAp) return;
      _homeWifiCheckTimer?.cancel();
      setState(() => _waitingForHomeWifi = false);
    });
  }

  Future<void> _checkSetupMode() async {
    setState(() {
      _step = _Step.checking;
      _statusMessage = 'Verifying speaker...';
    });
    final deviceId = await BoseWifiSetupService.getDeviceId();
    if (!mounted) return;
    if (deviceId == null) {
      setState(() {
        _error = 'Could not reach the speaker in setup mode. Make sure your phone is connected to the '
            'speaker\'s temporary WiFi (its name is usually the speaker model followed by a string '
            'of numbers), then try again.';
        _step = _Step.error;
      });
      return;
    }
    _deviceId = deviceId;
    setState(() => _step = _Step.form);
    unawaited(_scanNetworks());
  }

  Future<void> _scanNetworks() async {
    setState(() {
      _scanLoading = true;
      _scanError = null;
    });

    // Checked WITHOUT triggering the OS prompt yet (askPermissions: false) -
    // if location permission genuinely hasn't been decided on yet, show our
    // OWN plain-language rationale FIRST, so the system permission dialog
    // isn't the first and only explanation the user gets for why a speaker
    // WiFi-setup screen is asking for their location. Skipped entirely once
    // the user has already decided (granted or denied) - this is a one-time
    // explanation, not a repeated nag.
    final currentStatus = await WiFiScan.instance.canStartScan(askPermissions: false);
    if (currentStatus == CanStartScan.noLocationPermissionRequired) {
      if (!mounted) return;
      final proceed = await _showLocationRationale();
      if (!proceed) {
        setState(() {
          _scanLoading = false;
          _scanError = 'Location permission is needed to list nearby WiFi networks. '
              'You can still type the network name in manually below.';
        });
        return;
      }
    }

    final canStart = await WiFiScan.instance.canStartScan(askPermissions: true);
    if (canStart != CanStartScan.yes) {
      if (!mounted) return;
      setState(() {
        _scanLoading = false;
        _scanError = 'Could not scan for WiFi (${canStart.name}). Make sure Location is turned on '
            '(Android requires it to see nearby WiFi networks), or just type it in manually.';
      });
      return;
    }

    await WiFiScan.instance.startScan();
    // Give the scan a moment to actually populate results.
    await Future.delayed(const Duration(seconds: 2));

    final canGet = await WiFiScan.instance.canGetScannedResults(askPermissions: true);
    if (canGet != CanGetScannedResults.yes) {
      if (!mounted) return;
      setState(() {
        _scanLoading = false;
        _scanError = 'Could not get scan results (${canGet.name}). Just type it in manually.';
      });
      return;
    }

    final results = await WiFiScan.instance.getScannedResults();
    // The network the phone is CURRENTLY connected to during this step is
    // the speaker's own temporary setup AP (see this screen's own doc
    // comment), never the user's home network - excluded below so it can
    // never be tapped by mistake. Confirmed as a real reported point of
    // confusion: the setup AP's own name showed up right at the top of a
    // list explicitly asking "which is your HOME network?" (naturally the
    // strongest signal, since the phone is actively associated with it),
    // and users assumed picking the network they were visibly already
    // connected to was the right/expected choice.
    final currentSsid = await _currentConnectedSsid();
    // Dedupe by SSID (multiple access points/mesh nodes can share one name),
    // keeping the strongest signal; drop hidden (blank-SSID) networks - no
    // name to show/select in a picker.
    final bySsid = <String, WiFiAccessPoint>{};
    for (final ap in results) {
      if (ap.ssid.isEmpty) continue;
      if (ap.ssid == currentSsid) continue;
      final existing = bySsid[ap.ssid];
      if (existing == null || ap.level > existing.level) {
        bySsid[ap.ssid] = ap;
      }
    }
    final networks = bySsid.values.toList()..sort((a, b) => b.level.compareTo(a.level));

    if (!mounted) return;
    setState(() {
      _networks = networks;
      _scanLoading = false;
    });
  }

  Future<String?> _currentConnectedSsid() async {
    try {
      final raw = await _networkInfo.getWifiName();
      if (raw == null) return null;
      // Android wraps this in literal double-quotes (a long-documented
      // network_info_plus/ConnectivityManager quirk) - stripped so this
      // compares equal to WiFiAccessPoint.ssid, which never has them.
      return raw.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }

  /// Plain-language explanation shown BEFORE the OS location-permission
  /// prompt (see [_scanNetworks]) - Android requires Location permission for
  /// ANY app to list nearby WiFi network names (a platform-wide restriction,
  /// since WiFi scan data can be used to estimate physical location - not
  /// something this app or the wifi_scan package chose). Stating that
  /// plainly, and exactly what this app actually does with it (nothing
  /// beyond showing the picker below - never recorded, stored, or sent
  /// anywhere), is both honest and the accurate basis for this app's Play
  /// Store Data Safety declaration (location: app functionality only, not
  /// shared, not stored).
  Future<bool> _showLocationRationale() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Location permission'),
        content: const Text(
          'Android requires Location permission for any app to see nearby WiFi network names - '
          'this is a platform requirement, not a choice this app makes.\n\n'
          'It\'s used only to show you the list of WiFi networks below, so you can pick your home '
          'network for the speaker. Your location is never recorded, stored, or sent anywhere.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  bool _looksOpen(WiFiAccessPoint ap) {
    final caps = ap.capabilities.toUpperCase();
    return !(caps.contains('WEP') || caps.contains('WPA') || caps.contains('PSK') || caps.contains('EAP'));
  }

  void _selectNetwork(WiFiAccessPoint ap) {
    setState(() {
      _selectedSsid = ap.ssid;
      _ssidCtrl.text = ap.ssid;
      _isOpenNetwork = _looksOpen(ap);
      _passwordCtrl.clear();
    });
  }

  Future<void> _submit() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() {
        _error = 'Enter the WiFi name (SSID) first.';
        _step = _Step.error;
      });
      return;
    }
    final deviceId = _deviceId;
    if (deviceId == null) {
      setState(() {
        _error = 'Lost the connection to the speaker. Try again from the start.';
        _step = _Step.error;
      });
      return;
    }
    setState(() {
      _step = _Step.submitting;
      _statusMessage = 'Sending WiFi credentials to the speaker...';
    });
    final result = await BoseWifiSetupService.sendWifiCredentials(
      deviceId: deviceId,
      homeSsid: _ssidCtrl.text.trim(),
      homePassword: _passwordCtrl.text,
      isOpenNetwork: _isOpenNetwork,
      onStatus: (status) {
        if (mounted) setState(() => _statusMessage = status);
      },
    );
    if (!mounted) return;
    if (result.success) {
      setState(() => _step = _Step.done);
      _watchForHomeWifi();
    } else {
      // result.detail names the specific stage the handshake died at (see
      // BoseWifiSetupService.sendWifiCredentials's doc comment) - shown
      // as-is instead of a generic "check your password" message, since a
      // wrong password is only one of several very different ways this can
      // fail (2026-07-28: a field report of this failing turned out to have
      // nothing to do with the password, but the old message said exactly
      // that every time).
      setState(() {
        _error = result.detail ?? 'The speaker didn\'t confirm it joined "${_ssidCtrl.text.trim()}".';
        _step = _Step.error;
      });
    }
  }

  void _searchForSpeaker() {
    // Additive, not destructive: the newly-provisioned speaker is added to
    // whatever's already connected, rather than replacing it.
    final controller = context.read<SpeakerController>();
    // Captured BEFORE discoverMoreSpeakers() (fire-and-forget, so this scan
    // hasn't had a chance to land yet) - true only for the "already had a
    // speaker, this is an additional one" case. When this is the very
    // FIRST speaker, HomeScreen's own body IS a live SearchingOverlay right
    // now (see its `_showDiscovery` gate) - popping back to it below is
    // already the correct, reactive "Continue to Player" screen, and used
    // to get a second, REDUNDANT SearchingOverlay pushed unconditionally on
    // top of it here - that second instance has no onDone (same as the
    // drawer's "Add / rescan speakers" entry), so its own "Continue to
    // Player" button could never appear no matter what, until the user
    // backed out of it to reveal the real one underneath. Confirmed as a
    // real reported bug, 2026-07-25.
    final hadExistingSpeaker = controller.sessions.isNotEmpty;
    controller.discoverMoreSpeakers();
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (hadExistingSpeaker) {
      // Lands on a fresh SearchingOverlay instead of popping straight back
      // to the Player page - the speaker having just joined the home
      // network a moment ago means the FIRST scan attempt can easily run
      // before it's actually finished getting a DHCP lease/booting up on
      // it, and SpeakerController._scanForSpeakers already retries every
      // 10s on a miss. Also gives the phone itself a few seconds to fall
      // back onto its own known home WiFi now that the speaker's temporary
      // AP has disappeared - a manual switch may still be needed if it
      // doesn't. HomeScreen itself has no equivalent screen to fall back
      // onto in this case (sessions was already non-empty, so it's showing
      // the normal Player page, not discovery), so this one is needed.
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchingOverlay()));
    }
  }

  void _retry() {
    setState(() {
      _step = _Step.instructions;
      _error = '';
      _deviceId = null;
      _selectedSsid = null;
      _manualEntry = false;
      _ssidCtrl.clear();
      _passwordCtrl.clear();
      _isOpenNetwork = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup New Speaker')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case _Step.instructions:
        return _instructionsStep();
      case _Step.checking:
        return _busyStep(_statusMessage);
      case _Step.form:
        return _formStep();
      case _Step.submitting:
        return _busyStep(_statusMessage);
      case _Step.done:
        return _doneStep();
      case _Step.error:
        return _errorStep();
    }
  }

  Widget _busyStep(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _instructionsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'This is for a new or factory-reset speaker that has no WiFi yet.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 20),
        const Text('Step 1', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text(
          'Open your phone\'s WiFi Settings, and connect it to the speaker\'s temporary WiFi '
          '(usually named after the speaker model, followed by a string of numbers, no password). '
          'If asked "No internet, stay connected?", choose "Yes/Stay Connected".',
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(color: const Color(0xFF1F1F1F), borderRadius: BorderRadius.circular(12)),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.speaker, size: 30, color: Colors.grey),
              SizedBox(width: 10),
              Icon(Icons.wifi, size: 18, color: Color(0xFF22C55E)),
              SizedBox(width: 10),
              Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
              SizedBox(width: 10),
              Icon(Icons.smartphone, size: 26, color: Colors.white),
            ],
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: _checkSetupMode, child: const Text('I\'m Connected — Continue')),
      ],
    );
  }

  Widget _formStep() {
    final showPicker = !_manualEntry && _selectedSsid == null;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Step 2', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            showPicker
                ? 'Choose your home WiFi network (this is what the speaker will permanently connect to).'
                : 'Enter the password for "${_ssidCtrl.text}".',
          ),
          const SizedBox(height: 16),
          if (showPicker) _networkPicker() else _passwordForm(),
        ],
      ),
    );
  }

  Widget _networkPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Detected WiFi networks', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _scanLoading ? null : _scanNetworks,
            ),
          ],
        ),
        if (_scanLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_scanError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_scanError!, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else if (_networks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No WiFi networks found.', style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _networks.length,
              itemBuilder: (context, i) {
                final ap = _networks[i];
                final open = _looksOpen(ap);
                return ListTile(
                  leading: Icon(_signalIcon(ap.level)),
                  title: Text(ap.ssid),
                  trailing: open ? null : const Icon(Icons.lock, size: 16, color: Colors.grey),
                  onTap: () => _selectNetwork(ap),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _manualEntry = true),
            child: const Text('Can\'t find your network? Type it in instead'),
          ),
        ),
      ],
    );
  }

  IconData _signalIcon(int levelDbm) {
    if (levelDbm >= -60) return Icons.wifi;
    if (levelDbm >= -75) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  Widget _passwordForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_manualEntry && _selectedSsid == null) ...[
          TextField(
            controller: _ssidCtrl,
            decoration: const InputDecoration(labelText: 'WiFi Name (SSID)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          enabled: !_isOpenNetwork,
          autofocus: _selectedSsid != null,
          decoration: InputDecoration(
            labelText: 'WiFi Password',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        CheckboxListTile(
          value: _isOpenNetwork,
          onChanged: (v) => setState(() => _isOpenNetwork = v ?? false),
          title: const Text('Open network (no password)'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() {
            _selectedSsid = null;
            _manualEntry = false;
            _ssidCtrl.clear();
            _passwordCtrl.clear();
            _isOpenNetwork = false;
          }),
          child: const Text('← Pick from the list again'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: _submit, child: const Text('Send to Speaker')),
      ],
    );
  }

  Widget _doneStep() {
    if (_waitingForHomeWifi) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 48),
          const SizedBox(height: 12),
          Text('The speaker joined "${_ssidCtrl.text.trim()}".'),
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          const Text(
            'Waiting for your phone to switch back to your home WiFi...',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'If it doesn\'t switch back on its own in a few seconds, switch it back manually in WiFi Settings.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () {
                _homeWifiCheckTimer?.cancel();
                setState(() => _waitingForHomeWifi = false);
              },
              child: const Text('Already back on your WiFi? Continue anyway'),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 48),
        const SizedBox(height: 12),
        Text('The speaker joined "${_ssidCtrl.text.trim()}".'),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _searchForSpeaker, child: const Text('Find the Speaker')),
      ],
    );
  }

  Widget _errorStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Color(0xFFFF6666), size: 48),
        const SizedBox(height: 12),
        Text(_error),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _retry, child: const Text('Try Again')),
      ],
    );
  }
}
