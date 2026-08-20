import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  HttpOverrides.global = MyHttpOverrides();
  runApp(const MyApp());
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kimi <-> DeepSeek',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, dynamic>> _history = [];
  final List<String> _inboxKimi = [];
  final List<String> _inboxDs = [];
  final TextEditingController _ctrl = TextEditingController();
  bool _loading = false;
  String _kimiKey = '';
  String _dsKey = '';
  String _target = 'both';

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _kimiKey = p.getString('kimi_key') ?? '';
      _dsKey = p.getString('ds_key') ?? '';
    });
  }

  Future<void> _saveKeys(String k, String d) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('kimi_key', k);
    await p.setString('ds_key', d);
    setState(() {
      _kimiKey = k;
      _dsKey = d;
    });
  }

  void _send(String text, String target) {
    if (text.trim().isEmpty) return;
    setState(() {
      _history.add({'role': 'user', 'content': text});
      if (target == 'kimi') _inboxKimi.add(text);
      else if (target == 'ds') _inboxDs.add(text);
      else {
        _inboxKimi.add(text);
        _inboxDs.add(text);
      }
    });
    _ctrl.clear();
  }

  List<Map<String, String>> _buildMsgs(String who, String last) {
    final msgs = <Map<String, String>>[];
    msgs.add({
      'role': 'system',
      'content': who == 'kimi'
          ? 'Ты — креативный генератор идей. Отвечай по-русски.'
          : 'Ты — критический аналитик. Отвечай по-русски.'
    });
    for (final h in _history) {
      final r = h['role'] as String;
      final c = h['content'] as String;
      if (c.trim().isEmpty) continue;
      if (r == 'user') msgs.add({'role': 'user', 'content': c});
      else if (r == 'kimi' && who == 'kimi') msgs.add({'role': 'assistant', 'content': c});
      else if (r == 'ds' && who == 'ds') msgs.add({'role': 'assistant', 'content': c});
      else if (r == 'kimi' && who == 'ds') msgs.add({'role': 'user', 'content': '[Kimi]: $c'});
      else if (r == 'ds' && who == 'kimi') msgs.add({'role': 'user', 'content': '[DeepSeek]: $c'});
    }
    msgs.add({'role': 'user', 'content': last});
    return msgs;
  }

  Future<String> _api(String url, String key, String model, List<Map<String, String>> msgs) async {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 30);
    
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $key');
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.write(jsonEncode({'model': model, 'messages': msgs, 'max_tokens': 2000}));
    
    final response = await request.close().timeout(const Duration(seconds: 90));
    final body = await response.transform(utf8.decoder).join();
    client.close();
    
    if (response.statusCode != 200) throw 'HTTP ${response.statusCode}';
    final d = jsonDecode(body);
    final c = d['choices']?[0]?['message']?['content'];
    if (c == null || c.toString().trim().isEmpty) throw 'Empty response';
    return c.toString();
  }

  Future<void> _callKimi() async {
    if (_kimiKey.isEmpty) {
      _keyDialog();
      return;
    }
    if (_inboxKimi.isEmpty) {
      setState(() => _history.add({'role': 'sys', 'content': '⚠️ Нет сообщений для Kimi'}));
      return;
    }
    setState(() => _loading = true);
    try {
      final t = _inboxKimi.removeAt(0);
      final r = await _api('https://api.moonshot.ai/v1/chat/completions', _kimiKey, 'kimi-k2.6', _buildMsgs('kimi', t));
      setState(() {
        _history.add({'role': 'kimi', 'content': r});
        _inboxDs.add(r);
      });
    } catch (e) {
      setState(() => _history.add({'role': 'sys', 'content': '⚠️ Kimi: $e'}));
    }
    setState(() => _loading = false);
  }

  Future<void> _callDs() async {
    if (_dsKey.isEmpty) {
      _keyDialog();
      return;
    }
    if (_inboxDs.isEmpty) {
      setState(() => _history.add({'role': 'sys', 'content': '⚠️ Нет сообщений для DeepSeek'}));
      return;
    }
    setState(() => _loading = true);
    try {
      final t = _inboxDs.removeAt(0);
      final r = await _api('https://api.deepseek.com/v1/chat/completions', _dsKey, 'deepseek-chat', _buildMsgs('ds', t));
      setState(() {
        _history.add({'role': 'ds', 'content': r});
        _inboxKimi.add(r);
      });
    } catch (e) {
      setState(() => _history.add({'role': 'sys', 'content': '⚠️ DeepSeek: $e'}));
    }
    setState(() => _loading = false);
  }

  void _keyDialog() {
    final kc = TextEditingController(text: _kimiKey);
    final dc = TextEditingController(text: _dsKey);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔑 API Keys'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: kc, decoration: const InputDecoration(labelText: 'Kimi Key')),
            const SizedBox(height: 8),
            TextField(controller: dc, decoration: const InputDecoration(labelText: 'DeepSeek Key')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              _saveKeys(kc.text, dc.text);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Color _color(String r) {
    if (r == 'user') return const Color(0xFF58A6FF);
    if (r == 'kimi') return const Color(0xFFF0883E);
    if (r == 'ds') return const Color(0xFF3FB950);
    return Colors.grey;
  }

  String _label(String r) {
    if (r == 'user') return '👤 Вы';
    if (r == 'kimi') return '🔥 Kimi';
    if (r == 'ds') return '🧊 DeepSeek';
    return '⚙️ Система';
  }

  @override
  Widget build(BuildContext context) {
    final fs = MediaQuery.of(context).size.width * 0.032;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 Kimi ↔ DeepSeek', style: TextStyle(fontSize: 15)),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _keyDialog),
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFF1F2937), borderRadius: BorderRadius.circular(12)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('K: ${_inboxKimi.length}', style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('D: ${_inboxDs.length}', style: const TextStyle(color: Color(0xFFF0883E), fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'kimi', label: Text('Kimi', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 'both', label: Text('Both', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: 'ds', label: Text('DeepSeek', style: TextStyle(fontSize: 12))),
            ],
            selected: {_target},
            onSelectionChanged: (s) => setState(() => _target = s.first),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _loading ? null : _callKimi,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text('▶ Kimi', style: TextStyle(fontSize: fs)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _loading ? null : _callDs,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text('▶ DeepSeek', style: TextStyle(fontSize: fs)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _loading
                        ? null
                        : () async {
                            if (_inboxKimi.isNotEmpty) {
                              await _callKimi();
                              await Future.delayed(const Duration(milliseconds: 500));
                              await _callDs();
                            } else if (_inboxDs.isNotEmpty) {
                              await _callDs();
                              await Future.delayed(const Duration(milliseconds: 500));
                              await _callKimi();
                            } else {
                              _inboxKimi.add('Начни диалог.');
                              await _callKimi();
                              await Future.delayed(const Duration(milliseconds: 500));
                              await _callDs();
                            }
                          },
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text('⏩ Auto', style: TextStyle(fontSize: fs)),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(6),
              itemCount: _history.length,
              itemBuilder: (ctx, i) {
                final m = _history[i];
                final r = m['role'] as String;
                final c = m['content'] as String;
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: r == 'user' ? const Color(0xFF0D1117) : const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(left: BorderSide(color: _color(r), width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label(r), style: TextStyle(fontSize: fs * 0.75, color: Colors.grey.shade500, fontWeight: FontWeight.bold)),
                      SelectableText(c, style: TextStyle(fontSize: fs, height: 1.2)),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: TextStyle(fontSize: fs),
                    decoration: InputDecoration(
                      hintText: 'To $_target...',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (t) => _send(t, _target),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () => _send(_ctrl.text, _target),
                  icon: const Icon(Icons.send, color: Color(0xFF58A6FF)),
                  iconSize: 22,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
