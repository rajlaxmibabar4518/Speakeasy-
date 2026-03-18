import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _user = FirebaseAuth.instance.currentUser;
  late Box _box;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _box = Hive.box('history');
    _load();
  }

  void _load() {
    if (_user == null) {
      setState(() => _items = []);
      return;
    }
    final list = List<dynamic>.from(_box.get(_user!.uid) ?? <dynamic>[]);
    setState(() => _items = list);
  }

  Future<void> _deleteItem(int index) async {
    if (_user == null) return;
    final list = List<dynamic>.from(_box.get(_user!.uid) ?? <dynamic>[]);
    list.removeAt(index);
    await _box.put(_user!.uid, list);
    _load();
  }

  Future<void> _clearAll() async {
    if (_user == null) return;
    await _box.put(_user!.uid, <dynamic>[]);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('History')),
        body: const Center(child: Text('Please sign in to view history.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear all',
            onPressed: _items.isEmpty
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Clear history?'),
                        content: const Text('This will delete your saved translations.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear', style: TextStyle(color: Colors.red))),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await _clearAll();
                    }
                  },
          )
        ],
      ),
      body: _items.isEmpty
          ? const Center(child: Text('No history yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final item = _items[i] as Map;
                final src = item['src'] ?? '';
                final translated = item['translated'] ?? '';
                final from = item['from'] ?? '';
                final to = item['to'] ?? '';
                final ts = item['ts'] ?? '';

                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    title: Text(src, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const SizedBox(height: 6),
                      Text(translated, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text('${from.split('-').first.toUpperCase()} → ${to.split('-').first.toUpperCase()} • ${_formatTs(ts)}', style: const TextStyle(fontSize: 12)),
                    ]),
                    onTap: () {
                      // return this item to caller so it can re-run translation / fill input
                      Navigator.pop(context, {'src': src, 'from': from, 'to': to});
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Delete'),
                            content: const Text('Delete this history item?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                            ],
                          ),
                        );
                        if (ok == true) await _deleteItem(i);
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _formatTs(dynamic ts) {
    try {
      final dt = DateTime.parse(ts as String);
      return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';
    } catch (_) {
      return ts?.toString() ?? '';
    }
  }

  String _two(int v) => v.toString().padLeft(2, '0');
}
