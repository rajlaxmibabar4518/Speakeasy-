import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Box _settingsBox;

  bool _preferOffline = true;
  bool _autoDownloadModels = false;
  bool _rememberLastLangs = true;
  bool _isDarkTheme = false;
  double _ttsVolume = 0.7;

  @override
  void initState() {
    super.initState();
    _settingsBox = Hive.box('settings');
    _loadSettings();
  }

  void _loadSettings() {
    _preferOffline = _settingsBox.get('preferOffline', defaultValue: true);
    _autoDownloadModels = _settingsBox.get('autoDownloadModels', defaultValue: false);
    _rememberLastLangs = _settingsBox.get('rememberLastLangs', defaultValue: true);
    _ttsVolume = (_settingsBox.get('ttsVolume', defaultValue: 0.7) as num).toDouble();
    _isDarkTheme = _settingsBox.get('isDarkTheme', defaultValue: false);
    setState(() {});
  }

  Future<void> _saveSettings() async {
    await _settingsBox.put('preferOffline', _preferOffline);
    await _settingsBox.put('autoDownloadModels', _autoDownloadModels);
    await _settingsBox.put('rememberLastLangs', _rememberLastLangs);
    await _settingsBox.put('ttsVolume', _ttsVolume);
    await _settingsBox.put('isDarkTheme', _isDarkTheme);
  }

  Future<void> _clearCacheAndHistory() async {
    await Hive.box('translations').clear();
    await Hive.box('history').clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Translation cache & history cleared')),
    );
  }

  void _toggleTheme(bool value) {
    setState(() => _isDarkTheme = value);
    _settingsBox.put('isDarkTheme', value);
    // Notifies root widget to rebuild with new theme
    Navigator.of(context).pop(value);
  }

  void _close() async {
    await _saveSettings();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _saveSettings();
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.deepPurple,
          title: const Text('Settings'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _close,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text("Theme", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Dark Theme'),
              value: _isDarkTheme,
              onChanged: _toggleTheme,
            ),

            const SizedBox(height: 24),
            const Text("General", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Prefer offline translation when available'),
              value: _preferOffline,
              onChanged: (v) {
                setState(() => _preferOffline = v);
                _saveSettings();
              },
            ),
            SwitchListTile(
              title: const Text('Auto-download offline model'),
              value: _autoDownloadModels,
              onChanged: (v) {
                setState(() => _autoDownloadModels = v);
                _saveSettings();
              },
            ),
            SwitchListTile(
              title: const Text('Remember last used languages'),
              value: _rememberLastLangs,
              onChanged: (v) {
                setState(() => _rememberLastLangs = v);
                _saveSettings();
              },
            ),

            const SizedBox(height: 24),
            const Text('Voice & Audio', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Slider(
              value: _ttsVolume,
              min: 0.0,
              max: 1.0,
              divisions: 10,
              label: _ttsVolume.toStringAsFixed(1),
              onChanged: (v) {
                setState(() => _ttsVolume = v);
              },
              onChangeEnd: (v) => _saveSettings(),
            ),

            const SizedBox(height: 24),
            const Text("Storage", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text("Clear translation cache & history"),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Clear data?"),
                    content: const Text("This will delete all cached translations and history."),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text("Cancel"),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text("Clear", style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (ok == true) _clearCacheAndHistory();
              },
            ),
          ],
        ),
      ),
    );
  }
}
