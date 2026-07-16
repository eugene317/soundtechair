import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    } else {
      setState(() {
        _error = 'Hindi maabot ang speaker sa setup mode. Siguraduhing naka-connect ang phone mo sa '
            'temporary WiFi ng speaker (hal. "Bose SoundTouch XXXXXX"), tapos subukan ulit.';
        _step = _Step.error;
      });
    }
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _step = _Step.error;
      });
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
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hakbang 2', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('Ilagay ang detalye ng WiFi network ng bahay (kung saan permanenteng kokonekta ang speaker).'),
          const SizedBox(height: 16),
          TextField(
            controller: _ssidCtrl,
            decoration: const InputDecoration(labelText: 'WiFi Name (SSID)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            obscureText: _obscurePassword,
            enabled: !_isOpenNetwork,
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
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _submit, child: const Text('Ipadala sa Speaker')),
        ],
      ),
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
        const Text(
          'Antayin ang mga 15-30 segundo habang sumasali ang speaker sa WiFi ng bahay. '
          'Pagkatapos, ibalik ang WiFi ng phone mo pabalik sa parehong home network (hindi na sa speaker), '
          'tapos i-tap ang button sa ibaba para hanapin ang speaker.',
        ),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _searchForSpeaker, child: const Text('Naka-reconnect na ako — Hanapin ang Speaker')),
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
