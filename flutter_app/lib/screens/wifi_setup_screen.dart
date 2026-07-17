import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../services/wifi_control_service.dart';
import '../services/wifi_provisioning_service.dart';
import '../state/speaker_controller.dart';

enum _Step { instructions, checking, form, submitting, reconnectPrompt, error }

/// New/factory-reset speaker WiFi setup wizard. Based on a single
/// community-reverse-engineered protocol (see WifiProvisioningService docs) -
/// NOT official Bose documentation, so this screen is explicit and honest
/// about being a best-effort flow rather than a guaranteed one.
///
/// Deliberately does NOT attempt to programmatically join the speaker's
/// temporary WiFi network (that needs native Android WifiNetworkSpecifier
/// code, a real platform-specific risk of its own) - instead the two
/// WiFi-switching moments are manual steps the user does themselves in their
/// phone's own WiFi settings, which is simpler and far more reliable for a v1.
///
/// Step 2 (picking the home network) uses the PHONE's own WiFi scan (via the
/// wifi_scan package) rather than the speaker's own performWirelessSiteSurvey
/// action - the speaker's scan-RESPONSE format was never actually documented
/// anywhere during research (only the request shape was confirmed), while
/// Android's own WiFi scan API is standard and well-documented. Since the
/// phone is physically right next to the speaker during setup, it should see
/// the same home network the speaker itself would.
class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({super.key});

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  _Step _step = _Step.instructions;
  String _error = '';
  String? _resolvedSetupIp;

  final _ssidCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isOpenNetwork = false;
  bool _obscurePassword = true;

  bool _scanLoading = false;
  String? _scanError;
  List<WiFiAccessPoint> _networks = [];
  String? _selectedSsid;
  bool _manualEntry = false;

  /// null = attempting/not yet resolved, true = the disconnect() call
  /// itself reported success (doesn't guarantee Android actually rejoined
  /// the home network, just that this step ran without error), false =
  /// failed/threw.
  bool? _autoReconnectAttempted;

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkSetupMode() async {
    setState(() => _step = _Step.checking);
    final inSetupMode = await WifiProvisioningService.isInSetupMode();
    if (!mounted) return;
    if (inSetupMode) {
      setState(() => _step = _Step.form);
      unawaited(_scanNetworks());
    } else {
      setState(() {
        _error = 'Hindi maabot ang speaker sa setup mode. Siguraduhing naka-connect ang phone mo sa '
            'temporary WiFi ng speaker (hal. "Bose SoundTouch XXXXXX"), tapos subukan ulit.';
        _step = _Step.error;
      });
    }
  }

  Future<void> _scanNetworks() async {
    setState(() {
      _scanLoading = true;
      _scanError = null;
    });

    final canStart = await WiFiScan.instance.canStartScan(askPermissions: true);
    if (canStart != CanStartScan.yes) {
      if (!mounted) return;
      setState(() {
        _scanLoading = false;
        _scanError = 'Hindi ma-scan ang WiFi (${canStart.name}). Siguraduhing naka-on ang Location '
            'ng phone mo (kailangan ito ng Android para makakita ng WiFi networks), o mag-type na lang manually.';
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
        _scanError = 'Hindi makuha ang resulta ng scan (${canGet.name}). Mag-type na lang manually.';
      });
      return;
    }

    final results = await WiFiScan.instance.getScannedResults();
    // Dedupe by SSID (multiple access points/mesh nodes can share one name),
    // keeping the strongest signal; drop hidden (blank-SSID) networks - no
    // name to show/select in a picker.
    final bySsid = <String, WiFiAccessPoint>{};
    for (final ap in results) {
      if (ap.ssid.isEmpty) continue;
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
        _error = 'Ilagay muna ang pangalan ng WiFi (SSID).';
        _step = _Step.error;
      });
      return;
    }
    setState(() => _step = _Step.submitting);
    try {
      final ip = await WifiProvisioningService.submitWifiProfile(
        ssid: _ssidCtrl.text.trim(),
        password: _passwordCtrl.text,
        isOpenNetwork: _isOpenNetwork,
      );
      if (!mounted) return;
      setState(() {
        _resolvedSetupIp = ip;
        _step = _Step.reconnectPrompt;
      });
      unawaited(_attemptAutoReconnect());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _step = _Step.error;
      });
    }
  }

  /// Best-effort: disconnects the phone from the speaker's temporary AP,
  /// which (since the home network is normally already saved on the phone
  /// from before) should let Android auto-reconnect to it on its own,
  /// without the user needing to go into WiFi settings manually. This is a
  /// real platform-specific risk (WifiManager.disconnect() behavior varies
  /// across Android versions/OEMs, especially since Android 10+ restricts
  /// direct WiFi manipulation) - so the manual instructions stay visible
  /// regardless of what this reports, as a guaranteed fallback.
  Future<void> _attemptAutoReconnect() async {
    setState(() => _autoReconnectAttempted = null);
    try {
      final result = await WifiControlService.disconnect();
      if (!mounted) return;
      setState(() => _autoReconnectAttempted = result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _autoReconnectAttempted = false);
    }
  }

  void _searchForSpeaker() {
    context.read<SpeakerController>().rescanSpeaker();
    Navigator.of(context).popUntil((route) => route.isFirst);
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
        return const Center(child: CircularProgressIndicator());
      case _Step.form:
        return _formStep();
      case _Step.submitting:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Ipinapadala ang WiFi credentials sa speaker...'),
            ],
          ),
        );
      case _Step.reconnectPrompt:
        return _reconnectStep();
      case _Step.error:
        return _errorStep();
    }
  }

  Widget _instructionsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Ito ay para sa bagong o na-factory-reset na speaker na wala pang WiFi.\n\n'
          'Hindi opisyal na dokumentado ito ni Bose - batay ito sa community research. '
          'Puwedeng hindi ito gumana sa unang subok - subukan lang muli kung kinakailangan.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 20),
        const Text('Hakbang 1', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text(
          'Buksan ang WiFi Settings ng iyong phone, at ikonekta ito sa temporary WiFi '
          'ng speaker (karaniwang pangalan: "Bose SoundTouch XXXXXX", walang password). '
          'Kapag lumabas ang tanong na "No internet, stay connected?", piliin ang "Yes/Stay Connected".',
        ),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: _checkSetupMode, child: const Text('Nakakonekta na ako — Tuloy')),
      ],
    );
  }

  Widget _formStep() {
    final showPicker = !_manualEntry && _selectedSsid == null;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hakbang 2', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            showPicker
                ? 'Piliin ang WiFi network ng bahay mo (kung saan permanenteng kokonekta ang speaker).'
                : 'Ilagay ang password para sa "${_ssidCtrl.text}".',
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
            Text('Mga nakitang WiFi network', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'I-refresh',
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
            child: Text('Walang nakitang WiFi network.', style: TextStyle(color: Colors.grey, fontSize: 13)),
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
            child: const Text('Hindi mo nakita ang network mo? I-type na lang'),
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
          title: const Text('Open network (walang password)'),
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
          child: const Text('← Piliin ulit sa listahan'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: _submit, child: const Text('Ipadala sa Speaker')),
      ],
    );
  }

  Widget _reconnectStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 48),
        const SizedBox(height: 12),
        Text('Naipadala na ang WiFi credentials (via $_resolvedSetupIp).'),
        const SizedBox(height: 16),
        const Text('Hakbang 3', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        _autoReconnectStatus(),
        const SizedBox(height: 8),
        const Text(
          'Antayin ang mga 15-30 segundo habang sumasali ang speaker sa WiFi ng bahay. '
          'Kung HINDI awtomatikong bumalik ang WiFi ng phone mo (tingnan sa itaas), '
          'ibalik ito mano-mano sa WiFi Settings, tapos i-tap ang button sa ibaba para hanapin ang speaker.',
        ),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _searchForSpeaker, child: const Text('Naka-reconnect na ako — Hanapin ang Speaker')),
      ],
    );
  }

  Widget _autoReconnectStatus() {
    if (_autoReconnectAttempted == null) {
      return const Row(
        children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Sinusubukang awtomatikong ibalik ang WiFi ng phone mo...', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    if (_autoReconnectAttempted == true) {
      return const Row(
        children: [
          Icon(Icons.check, size: 16, color: Color(0xFF22C55E)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Sinubukan nang awtomatikong ibalik ang WiFi mo. Kumpirmahin lang sa itaas ng screen mo.',
              style: TextStyle(fontSize: 12, color: Color(0xFF22C55E)),
            ),
          ),
        ],
      );
    }
    return const Row(
      children: [
        Icon(Icons.info_outline, size: 16, color: Colors.grey),
        SizedBox(width: 6),
        Expanded(
          child: Text(
            'Hindi na-automate sa phone na ito - kailangang mano-mano.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
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
        ElevatedButton(onPressed: () => setState(() => _step = _Step.instructions), child: const Text('Subukan Ulit')),
      ],
    );
  }
}
