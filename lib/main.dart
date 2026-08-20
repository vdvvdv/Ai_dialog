import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kimi ↔ DeepSeek Dialog',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(primary: Colors.green.shade700),
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
  final List<Map<String, String>> _history = [];
  final List<String> _inboxKimi = [];
  final List<String> _inboxDs = [];
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  String _kimiKey = '';
  String _dsKey = '';

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _kimiKey = prefs.getString('kimi_key') ?? '';
      _dsKey = prefs.getString('ds_key') ?? '';
    });
  }

  Future<void> _saveKeys(String kimiKey, String dsKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kimi_key', kimiKey);
    await prefs.setString('ds_key', dsKey);
    setState(() {
      _kimiKey = kimiKey;
      _dsKey = dsKey;
    });
  }

  void _sendMessage(String text, String target) {
    if (text.trim().isEmpty) return;
    setState(() {
      _history.add({'role': 'user', 'content': text, 'target': target});
      if (target == 'kimi') {
        _inboxKimi.add(text);
      } else {
        _inboxDs.add(text);
      }
    });
    _controller.clear();
    _processNextTurn();
  }

  Future<void> _processNextTurn() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      if (_inboxKimi.isNotEmpty) {
        await _callKimi();
      } else if (_inboxDs.isNotEmpty) {
        await _callDeepSeek();
      } else {
        _inboxKimi.add('Начни диалог о разработке AI-приложений.');
        await _callKimi();
      }
    } catch (e) {
      setState(() {
        _history.add({'role': 'system', 'content': '⚠️ Ошибка: $e', 'target': 'system'});
      });
    }

    setState(() => _isLoading = false);
  }

  Future<void> _callKimi() async {
    if (_kimiKey.isEmpty) {
      _showKeyDialog('Kimi');
      return;
    }

    final msg = _inboxKimi.removeAt(0);
    final response = await _callApi('kimi', msg);
    setState(() {
      _history.add({'role': 'kimi', 'content': response, 'target': 'kimi'});
      _inboxDs.add(response);
    });
  }

  Future<void> _callDeepSeek() async {
    if (_dsKey.isEmpty) {
      _showKeyDialog('DeepSeek');
      return;
    }

    final msg = _inboxDs.removeAt(0);
    final response = await _callApi('ds', msg);
    setState(() {
      _history.add({'role': 'ds', 'content': response, 'target': 'ds'});
      _inboxKimi.add(response);
    }); thanks 
  }
    Future<String> _callApi(String model, String prompt) async {
    if (model == 'kimi') {
      final url = Uri.parse('https://api.moonshot.cn/v1/chat/completions');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_kimiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'moonshot-v1-8k',
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'max_tokens': 2000,
        }),
      );
      if (response.statusCode != 200) {
        throw 'Kimi API error: ${response.statusCode}';
      }
      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'];
    } else {
      final url = Uri.parse('https://api.deepseek.com/v1/chat/completions');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_dsKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'deepseek-chat',
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'max_tokens': 2000,
        }),
      );
      if (response.statusCode != 200) {
        throw 'DeepSeek API error: ${response.statusCode}';
      }
      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'];
    }
  }

  void _showKeyDialog(String model) {
    final kimiCtrl = TextEditingController(text: _kimiKey);
    final dsCtrl = TextEditingController(text: _dsKey);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔑 Введите API ключи'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: kimiCtrl,
              decoration: const InputDecoration(
                labelText: 'Kimi API Key (Moonshot)',
                hintText: 'sk-...',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: dsCtrl,
              decoration: const InputDecoration(
                labelText: 'DeepSeek API Key',
                hintText: 'sk-...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              _saveKeys(kimiCtrl.text, dsCtrl.text);
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 Kimi ↔ DeepSeek'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showKeyDialog(''),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('📨 Kimi: ', style: TextStyle(fontSize: 11)),
                Text(
                  '${_inboxKimi.length}',
                  style: const TextStyle(
                    color: Color(0xFF58A6FF),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('DS: ', style: TextStyle(fontSize: 11)),
                Text(
                  '${_inboxDs.length}',
                  style: const TextStyle(
                    color: Color(0xFFF0883E),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : () => _processNextTurn(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('▶ Kimi turn'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : () => _processNextTurn(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('▶ DeepSeek turn'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : () {
                      if (_inboxKimi.isEmpty && _inboxDs.isEmpty) {
                        _inboxKimi.add('Начни диалог о разработке AI-приложений.');
                      }
                      _processNextTurn();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('⏩ Auto'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _history.length,
              itemBuilder: (ctx, index) {
                final msg = _history[index];
                final role = msg['role']!;
                final content = msg['content']!;
                
                Color color;
                String label;
                if (role == 'user') {
                  color = const Color(0xFF58A6FF);
                  label = '👤 Вы';
                } else if (role == 'kimi') {
                  color = const Color(0xFFF0883E);
                  label = '🔥 Kimi';
                } else if (role == 'ds') {
                  color = const Color(0xFFF0883E);
                  label = '🧊 DeepSeek';
                } else {
                  color = Colors.grey;
                  label = '⚙️ Система';
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: role == 'user' ? const Color(0xFF0D1117) : const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(left: BorderSide(color: color, width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        content,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Написать одному из ИИ...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (text) => _sendMessage(text, 'kimi'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _sendMessage(_controller.text, 'kimi'),
                  icon: const Icon(Icons.send, color: Color(0xFF58A6FF)),
                ),
                IconButton(
                  onPressed: () => _sendMessage(_controller.text, 'ds'),
                  icon: const Icon(Icons.send, color: Color(0xFFF0883E)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
