import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/search_api_client.dart';
import '../services/settings_service.dart';
import '../state/speaker_controller.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool isOnboarding;

  const SettingsScreen({super.key, this.isOnboarding = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _searchServerCtrl;
  late final TextEditingController _streamProxyCtrl;
  final _manualIpCtrl = TextEditingController();
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SpeakerController>().settings;
    _searchServerCtrl = TextEditingController(
      text: settings.searchServerUrl.isEmpty ? SettingsService.defaultSearchServerUrl : settings.searchServerUrl,
    );
    _streamProxyCtrl = TextEditingController(
      text: settings.streamProxyUrl.isEmpty ? SettingsService.defaultStreamProxyUrl : settings.streamProxyUrl,
    );
  }

  @override
  void dispose() {
    _searchServerCtrl.dispose();
    _streamProxyCtrl.dispose();
    _manualIpCtrl.dispose();
    super.dispose();
  }

  Future<void> _testSearchServer() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final results = await SearchApiClient.searchYoutube(_searchServerCtrl.text.trim(), 'test');
      setState(() => _testResult = 'OK - got ${results.length} result(s)');
    } catch (e) {
      setState(() => _testResult = 'Error: $e');
    }
    setState(() => _testing = false);
  }

  Future<void> _saveAndContinue() async {
    final controller = context.read<SpeakerController>();
    final newSettings = AppSettings(
      searchServerUrl: _searchServerCtrl.text.trim(),
      streamProxyUrl: _streamProxyCtrl.text.trim(),
    );
    await controller.updateSettings(newSettings);
    if (!mounted) return;
    if (widget.isOnboarding) {
      await controller.init();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.isOnboarding) ...[
              const Text(
                'Before we start, confirm the Online Server\'s address.',
                style: TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 16),
            ],
            const Text('Search Server URL', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              controller: _searchServerCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'https://...trycloudflare.com',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _testing ? null : _testSearchServer,
                  child: Text(_testing ? 'Testing...' : 'Test Search Server'),
                ),
                if (_testResult != null) ...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(_testResult!, style: const TextStyle(fontSize: 12))),
                ],
              ],
            ),
            const SizedBox(height: 24),
            const Text('Stream Proxy URL', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              controller: _streamProxyCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'https://...trycloudflare.com',
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Run cloudflared tunnel --url http://localhost:5001 on the server, '
              'then paste the printed https://...trycloudflare.com URL here to enable '
              'playing search results.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _saveAndContinue, child: const Text('Save & Continue')),
            if (!widget.isOnboarding) ...[
              const Divider(height: 48),
              const Text('Speaker', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Consumer<SpeakerController>(
                builder: (context, controller, _) => Text(
                  controller.speaker != null
                      ? '${controller.speaker!.name} (${controller.speaker!.ip})'
                      : 'Not connected',
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => context.read<SpeakerController>().rescanSpeaker(),
                child: const Text('Rescan now'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _manualIpCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Manual speaker IP override',
                  hintText: '192.168.1.4',
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () {
                  final ip = _manualIpCtrl.text.trim();
                  if (ip.isNotEmpty) context.read<SpeakerController>().setManualIp(ip);
                },
                child: const Text('Connect to this IP'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
