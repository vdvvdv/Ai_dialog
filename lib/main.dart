import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
  static const _kimiUrl = 'https://api.moonshot.ai/v1/chat/completions';
  static const _dsUrl = 'https://api.deepseek.com/v1/chat/completions';

  static const _kimiModels = [
    'kimi-k2.6',
    'kimi-k2.5',
    'kimi-k2-0905-preview',
    'moonshot-v1-8k',
    'moonshot-v1-32k',
    'moonshot-v1-128k',
  ];
  static const _dsModels = [
    'deepseek-chat',
    'deepseek-reasoner',
  ];

  final List<Map<String, String>> _history = [];
  final List<String> _inboxKimi = [];
  final List<String> _inboxDs = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _loading = false;
  bool _autoLoop = false;
  String _kimiKey = '';
  String _dsKey = '';
  String _kimiModel = 'kimi-k2.6';
  String _dsModel = 'deepseek-chat';
  int _maxTokens = 4000;
  int _timeoutSec = 180;
  String _target = 'both';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _kimiKey = p.getString('kimi_key') ?? '';
      _dsKey = p.getString('ds_key') ?? '';
      _kimiModel = p.getString('kimi_model') ?? _kimiModel;
      _dsModel = p.getString('ds_model') ?? _dsModel;
      _maxTokens = p.getInt('max_tokens') ?? _maxTokens;
      _timeoutSec = p.getInt('timeout_sec') ?? _timeoutSec;
    });
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('kimi_key', _kimiKey);
    await p.setString('ds_key', _dsKey);
    await p.setString('kimi_model', _kimiModel);
    await p.setString('ds_model', _dsModel);
    await p.setInt('max_tokens', _maxTokens);
    await p.setInt('timeout_sec', _timeoutSec);
  }

  // ---------- Отправка ----------

  void _send(String text, String target) {
    if (text.trim().isEmpty) return;
    setState(() {
      _history.add({'role': 'user', 'content': text});
      if (target == 'kimi') {
        _inboxKimi.add(text);
      } else if (target == 'ds') {
        _inboxDs.add(text);
      } else {
        _inboxKimi.add(text);
        _inboxDs.add(text);
      }
    });
    _ctrl.clear();
    _scrollBottom();
  }

  /// Формирует messages из истории. Текст из очереди уже есть в истории,
  /// поэтому отдельно дублировать его не нужно.
  List<Map<String, String>> _buildMsgs(String who) {
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
      if (c.trim().isEmpty || c == '…') continue;
      if (r == 'user') {
        msgs.add({'role': 'user', 'content': c});
      } else if (r == 'kimi' && who == 'kimi') {
        msgs.add({'role': 'assistant', 'content': c});
      } else if (r == 'ds' && who == 'ds') {
        msgs.add({'role': 'assistant', 'content': c});
      } else if (r == 'kimi' && who == 'ds') {
        msgs.add({'role': 'user', 'content': '[Kimi]: $c'});
      } else if (r == 'ds' && who == 'kimi') {
        msgs.add({'role': 'user', 'content': '[DeepSeek]: $c'});
      }
    }
    return msgs;
  }

  // ---------- Потоковый запрос ----------

  /// Возвращает полный текст ответа, по мере поступления вызывает onChunk.
  /// При пустом ответе бросает исключение с диагностикой (finish_reason, usage).
  Future<String> _apiStream(String url, String key, String model,
      List<Map<String, String>> msgs, void Function(String) onChunk) async {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 30);

    String finishReason = '';
    String usage = '';
    final buf = StringBuffer();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $key');
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.write(jsonEncode({
        'model': model,
        'messages': msgs,
        'max_tokens': _maxTokens,
        'stream': true,
      }));

      final response = await request.close();
      if (response.statusCode != 200) {
        final errBody = await response.transform(utf8.decoder).join();
        final short =
            errBody.length > 300 ? '${errBody.substring(0, 300)}…' : errBody;
        throw 'HTTP ${response.statusCode}: $short';
      }

      // Таймаут применяется к паузе МЕЖДУ порциями потока, а не ко всему ответу.
      final stream = response
          .transform(utf8.decoder)
          .timeout(Duration(seconds: _timeoutSec));

      var lineBuf = '';
      await for (final chunk in stream) {
        lineBuf += chunk;
        int nl;
        while ((nl = lineBuf.indexOf('\n')) >= 0) {
          final line = lineBuf.substring(0, nl).trim();
          lineBuf = lineBuf.substring(nl + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data == '[DONE]' || data.isEmpty) continue;
          try {
            final j = jsonDecode(data);
            final choice = j['choices']?[0];
            final delta = choice?['delta']?['content'];
            final fr = choice?['finish_reason'];
            if (fr != null) finishReason = fr.toString();
            if (j['usage'] != null) usage = j['usage'].toString();
            if (delta != null) {
              buf.write(delta);
              onChunk(buf.toString());
            }
          } catch (_) {
            // неполная строка JSON — пропускаем
          }
        }
      }
    } on TimeoutException {
      throw 'Таймаут: нет данных ${_timeoutSec}с (сгенерировано ${buf.length} симв.)';
    } finally {
      client.close();
    }

    final result = buf.toString();
    if (result.trim().isEmpty) {
      throw 'Пустой ответ (finish_reason: ${finishReason.isEmpty ? "нет" : finishReason}'
          '${usage.isEmpty ? "" : ", usage: $usage"})';
    }
    if (finishReason == 'length') {
      throw 'Ответ обрезан по max_tokens=$_maxTokens '
          '(увеличьте лимит в настройках). Получено: ${result.length} симв.';
    }
    return result;
  }

  // ---------- Вызовы моделей ----------

  Future<void> _callModel({
    required String who, // 'kimi' | 'ds'
    required String url,
    required String key,
    required String model,
    required List<String> inbox,
    required List<String> otherInbox,
  }) async {
    if (key.isEmpty) {
      _settingsDialog();
      return;
    }
    if (inbox.isEmpty) {
      setState(() => _history.add({
            'role': 'sys',
            'content': '⚠️ Нет сообщений для ${who == 'kimi' ? 'Kimi' : 'DeepSeek'}'
          }));
      return;
    }
    // Вопрос НЕ удаляется из очереди до успешного ответа.
    final msgs = _buildMsgs(who);
    setState(() {
      _loading = true;
      _history.add({'role': who, 'content': '…'});
    });
    final idx = _history.length - 1;
    _scrollBottom();
    try {
      final r = await _apiStream(url, key, model, msgs, (partial) {
        if (mounted) setState(() => _history[idx]['content'] = partial);
      });
      setState(() {
        inbox.removeAt(0); // успех — теперь удаляем
        _history[idx]['content'] = r;
        otherInbox.add(r);
      });
      _scrollBottom();
    } catch (e) {
      setState(() {
        _history.removeAt(idx); // убираем пустышку, вопрос остался в очереди
        _autoLoop = false;
      });
      _retrySnack(who == 'kimi' ? 'Kimi' : 'DeepSeek', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _callKimi() => _callModel(
        who: 'kimi',
        url: _kimiUrl,
        key: _kimiKey,
        model: _kimiModel,
        inbox: _inboxKimi,
        otherInbox: _inboxDs,
      );

  Future<void> _callDs() => _callModel(
        who: 'ds',
        url: _dsUrl,
        key: _dsKey,
        model: _dsModel,
        inbox: _inboxDs,
        otherInbox: _inboxKimi,
      );

  void _retrySnack(String who, Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('⚠️ $who: $e\nВопрос сохранён в очереди.'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: 'Повторить',
        onPressed: () => who == 'Kimi' ? _callKimi() : _callDs(),
      ),
    ));
  }

  /// Непрерывный авто-диалог, пока есть сообщения в очередях.
  Future<void> _auto() async {
    if (_autoLoop) {
      setState(() => _autoLoop = false); // повторное нажатие — стоп
      return;
    }
    if (_inboxKimi.isEmpty && _inboxDs.isEmpty) {
      _send('Начни диалог.', 'kimi');
    }
    setState(() => _autoLoop = true);
    while (_autoLoop && mounted) {
      if (_inboxKimi.isNotEmpty) {
        await _callKimi();
      } else if (_inboxDs.isNotEmpty) {
        await _callDs();
      } else {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (mounted) setState(() => _autoLoop = false);
  }

  void _scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ---------- Настройки ----------

  void _settingsDialog() {
    final kc = TextEditingController(text: _kimiKey);
    final dc = TextEditingController(text: _dsKey);
    final mc = TextEditingController(text: _maxTokens.toString());
    final tc = TextEditingController(text: _timeoutSec.toString());
    String km = _kimiModel;
    String dm = _dsModel;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('⚙️ Настройки'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: kc,
                  decoration: const InputDecoration(labelText: 'Kimi Key'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: dc,
                  decoration: const InputDecoration(labelText: 'DeepSeek Key'),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _kimiModels.contains(km) ? km : _kimiModels.first,
                  decoration: const InputDecoration(labelText: 'Модель Kimi'),
                  items: _kimiModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setD(() => km = v ?? km),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _dsModels.contains(dm) ? dm : _dsModels.first,
                  decoration: const InputDecoration(labelText: 'Модель DeepSeek'),
                  items: _dsModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setD(() => dm = v ?? dm),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: mc,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'max_tokens (лимит ответа)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Таймаут паузы потока, сек'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _kimiKey = kc.text.trim();
                  _dsKey = dc.text.trim();
                  _kimiModel = km;
                  _dsModel = dm;
                  _maxTokens = int.tryParse(mc.text) ?? _maxTokens;
                  _timeoutSec = int.tryParse(tc.text) ?? _timeoutSec;
                });
                _saveSettings();
                Navigator.pop(ctx);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Экран очередей ----------

  void _openQueues() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QueueScreen(
          inboxKimi: _inboxKimi,
          inboxDs: _inboxDs,
          onChanged: () => setState(() {}),
        ),
      ),
    );
  }

  // ---------- UI ----------

  Color _color(String r) {
    if (r == 'user') return const Color(0xFF58A6FF);
    if (r == 'kimi') return const Color(0xFFF0883E);
    if (r == 'ds') return const Color(0xFF3FB950);
    return Colors.grey;
  }

  String _label(String r) {
    if (r == 'user') return '👤 Вы';
    if (r == 'kimi') return '🔥 Kimi ($_kimiModel)';
    if (r == 'ds') return '🧊 DeepSeek ($_dsModel)';
    return '⚙️ Система';
  }

  @override
  Widget build(BuildContext context) {
    final fs = MediaQuery.of(context).size.width * 0.032;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 Kimi ↔ DeepSeek', style: TextStyle(fontSize: 15)),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _settingsDialog),
          InkWell(
            onTap: _openQueues,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: const Color(0xFF1F2937),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('K: ${_inboxKimi.length}',
                      style: const TextStyle(
                          color: Color(0xFF58A6FF),
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Text('D: ${_inboxDs.length}',
                      style: const TextStyle(
                          color: Color(0xFFF0883E),
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'kimi',
                  label: Text('Kimi', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: 'both',
                  label: Text('Both', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: 'ds',
                  label: Text('DeepSeek', style: TextStyle(fontSize: 12))),
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
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text('▶ Kimi', style: TextStyle(fontSize: fs)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _loading ? null : _callDs,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text('▶ DeepSeek', style: TextStyle(fontSize: fs)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _loading ? null : _auto,
                    style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _autoLoop ? Colors.red.shade700 : Colors.blue.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text(_autoLoop ? '⏹ Стоп' : '⏩ Auto',
                        style: TextStyle(fontSize: fs)),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
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
                    color: r == 'user'
                        ? const Color(0xFF0D1117)
                        : const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border(left: BorderSide(color: _color(r), width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label(r),
                          style: TextStyle(
                              fontSize: fs * 0.75,
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.bold)),
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
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
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

/// Экран просмотра и управления очередями сообщений к моделям.
class QueueScreen extends StatefulWidget {
  final List<String> inboxKimi;
  final List<String> inboxDs;
  final VoidCallback onChanged;

  const QueueScreen({
    super.key,
    required this.inboxKimi,
    required this.inboxDs,
    required this.onChanged,
  });

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  void _refresh() {
    setState(() {});
    widget.onChanged();
  }

  Future<void> _edit(List<String> q, int i, String title) async {
    final c = TextEditingController(text: q[i]);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Редактировать ($title)'),
        content: TextField(
          controller: c,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('OK')),
        ],
      ),
    );
    if (res != null && res.trim().isNotEmpty) {
      q[i] = res;
      _refresh();
    }
  }

  void _move(List<String> q, int i, int dir) {
    final j = i + dir;
    if (j < 0 || j >= q.length) return;
    final t = q[i];
    q[i] = q[j];
    q[j] = t;
    _refresh();
  }

  Widget _section(String title, Color color, List<String> q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('$title (${q.length})',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
              if (q.isNotEmpty)
                TextButton(
                  onPressed: () {
                    q.clear();
                    _refresh();
                  },
                  child: const Text('Очистить',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
            ],
          ),
        ),
        if (q.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text('— пусто —',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        for (var i = 0; i < q.length; i++)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: const Color(0xFF1F2937),
            child: ListTile(
              dense: true,
              title: Text(q[i],
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text('#${i + 1}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      onPressed: () => _move(q, i, -1)),
                  IconButton(
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      onPressed: () => _move(q, i, 1)),
                  IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _edit(q, i, title)),
                  IconButton(
                      icon: const Icon(Icons.delete,
                          size: 18, color: Colors.redAccent),
                      onPressed: () {
                        q.removeAt(i);
                        _refresh();
                      }),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📬 Очереди сообщений')),
      body: ListView(
        children: [
          _section('Очередь Kimi', const Color(0xFF58A6FF), widget.inboxKimi),
          const Divider(),
          _section('Очередь DeepSeek', const Color(0xFFF0883E), widget.inboxDs),
        ],
      ),
    );
  }
}
