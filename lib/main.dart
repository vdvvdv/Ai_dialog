import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
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
  static const _kimiBase = 'https://api.moonshot.ai/v1';
  static const _dsBase = 'https://api.deepseek.com/v1';
  static const _kimiUrl = '$_kimiBase/chat/completions';
  static const _dsUrl = '$_dsBase/chat/completions';
  static const _appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  static const _kimiModels = [
    'kimi-k2.7-code',
    'kimi-k2.6',
    'kimi-k3',
    'kimi-k2-0905-preview',
    'kimi-k2.5',
    'moonshot-v1-8k',
    'moonshot-v1-32k',
    'moonshot-v1-128k',
  ];
  static const _dsModels = [
    'deepseek-v4-flash',
    'deepseek-v4-pro',
    'deepseek-chat',
    'deepseek-reasoner',
  ];
  static const _efforts = ['default', 'low', 'medium', 'high'];
  static const _strategies = ['smart', 'last20', 'full'];

  final List<Map<String, String>> _history = [];
  final List<String> _inboxKimi = [];
  final List<String> _inboxDs = [];
  final List<String> _errorLog = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Map<String, dynamic>> _kimiInfo = [];
  List<Map<String, dynamic>> _dsInfo = [];
  String _modelsSrc = 'встроенный список';
  String _modelsErr = '';
  String _connInfo = '';

  bool _loading = false;
  bool _autoLoop = false;
  bool _stopRequested = false;
  bool _awaitingComment = false;
  bool _showThinking = true;
  String _status = '';
  String _kimiKey = '';
  String _dsKey = '';
  String _kimiModel = 'kimi-k2.6';
  String _dsModel = 'deepseek-chat';
  String _reasoningEffort = 'default';
  String _keepStrategy = 'smart';
  String _historySummary = '';
  int _maxTokens = 32000;
  int _timeoutSec = 180;
  int _step = 0;
  int _reqSeq = 0;
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
      _reasoningEffort = p.getString('reasoning_effort') ?? _reasoningEffort;
      _keepStrategy = p.getString('keep_strategy') ?? _keepStrategy;
      _maxTokens = p.getInt('max_tokens') ?? _maxTokens;
      _timeoutSec = p.getInt('timeout_sec') ?? _timeoutSec;
      _showThinking = p.getBool('show_thinking') ?? _showThinking;
    });
    _restoreState(p);
  }

  void _restoreState(SharedPreferences p) {
    try {
      final raw = p.getString('state');
      if (raw == null || raw.isEmpty) return;
      final d = jsonDecode(raw);
      setState(() {
        for (final m in (d['history'] as List)) {
          _history.add(Map<String, String>.from(m));
        }
        _inboxKimi.addAll(List<String>.from(d['kimi'] ?? []));
        _inboxDs.addAll(List<String>.from(d['ds'] ?? []));
        _errorLog.addAll(List<String>.from(d['log'] ?? []));
        _step = d['step'] ?? 0;
        _reqSeq = d['reqseq'] ?? 0;
        _historySummary = d['summary'] ?? '';
      });
      if (_history.isNotEmpty) {
        setState(() => _status =
            '♻️ Состояние восстановлено (шаг $_step, очереди K:${_inboxKimi.length} D:${_inboxDs.length})');
      }
    } catch (e) {
      _logError('restore', e.toString());
    }
  }

  Future<void> _persistState() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'state',
          jsonEncode({
            'history': _history,
            'kimi': _inboxKimi,
            'ds': _inboxDs,
            'log': _errorLog,
            'step': _step,
            'reqseq': _reqSeq,
            'summary': _historySummary,
          }));
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('kimi_key', _kimiKey);
    await p.setString('ds_key', _dsKey);
    await p.setString('kimi_model', _kimiModel);
    await p.setString('ds_model', _dsModel);
    await p.setString('reasoning_effort', _reasoningEffort);
    await p.setString('keep_strategy', _keepStrategy);
    await p.setInt('max_tokens', _maxTokens);
    await p.setInt('timeout_sec', _timeoutSec);
    await p.setBool('show_thinking', _showThinking);
  }

  // ---------- Журнал ----------

  void _logLine(String line) {
    final t = DateTime.now().toString().substring(11, 19);
    _errorLog.add('[$t] $line');
    if (_errorLog.length > 500) _errorLog.removeAt(0);
    _persistState();
  }

  void _logError(String who, String err) => _logLine('ERR $who: $err');

  void _logReq(Map<String, dynamic> m) => _logLine(jsonEncode(m));

  String _now() => DateTime.now().toString().substring(11, 19);

  int _estTokens(List<Map<String, String>> msgs) {
    var chars = 0;
    for (final m in msgs) {
      chars += (m['content'] ?? '').length;
    }
    return chars ~/ 3;
  }

  int _contextLimit(String model) {
    if (model.contains('128k')) return 128000;
    if (model.contains('32k')) return 32000;
    if (model.contains('8k')) return 8192;
    if (model.startsWith('deepseek')) return 1000000;
    return 131072;
  }

  // ---------- Список моделей с сервера ----------

  /// Встроенная таблица характеристик (фолбэк, если API не отдал поля).
  Map<String, dynamic> _modelMeta(String id) {
    var ctx = 131072;
    if (id.contains('128k')) ctx = 128000;
    if (id.contains('32k') && !id.contains('k2')) ctx = 32000;
    if (id.contains('8k')) ctx = 8192;
    if (id.startsWith('deepseek')) ctx = 1000000;
    final reasoning = id.startsWith('kimi-k3') ||
        id.startsWith('kimi-k2.6') ||
        id.startsWith('kimi-k2.7') ||
        id.contains('thinking') ||
        id.contains('reasoner');
    final vision = id.contains('vision') ||
        id.contains('k2.5') ||
        id == 'kimi-latest';
    return {'ctx': ctx, 'reasoning': reasoning, 'vision': vision};
  }

  String _metaStr(int ctx, bool reasoning, bool vision) {
    final c = ctx >= 1000000
        ? '${(ctx / 1000000).toStringAsFixed(0)}M'
        : '${(ctx / 1000).toStringAsFixed(0)}K';
    return '$c контекст${reasoning ? ' · 🧠 reasoning' : ''}'
        '${vision ? ' · 👁 мультимод.' : ''}';
  }

  Future<void> _fetchModelsLists() async {
    Future<List<Map<String, dynamic>>> one(String base, String key) async {
      final r = await http.get(Uri.parse('$base/models'), headers: {
        'Authorization': 'Bearer $key',
        'Accept-Encoding': 'gzip',
      }).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      final out = <Map<String, dynamic>>[];
      for (final m in (d['data'] as List)) {
        final id = m['id'].toString();
        if (id.isEmpty) continue;
        final meta = _modelMeta(id);
        out.add({
          'id': id,
          'ctx': m['context_length'] ??
              m['max_context_length'] ??
              meta['ctx'],
          'reasoning':
              m['supports_reasoning'] ?? m['reasoning'] ?? meta['reasoning'],
          'vision': m['supports_vision'] ?? m['vision'] ?? meta['vision'],
        });
      }
      out.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      return out;
    }

    var got = 0;
    _modelsErr = '';
    _connInfo = '';
    if (_kimiKey.isNotEmpty) {
      var swK = Stopwatch()..start();
      final vpnK = await _vpnActive();
      try {
        _kimiInfo = await one(_kimiBase, _kimiKey);
        got++;
        _connInfo += 'Kimi ✓ ${swK.elapsedMilliseconds}мс  ';
        _logReq({'type': 'models', 'who': 'kimi',
            'ms': swK.elapsedMilliseconds, 'ok': true, 'vpn': vpnK});
      } catch (e) {
        _logError('models-kimi', e.toString());
        _logReq({'type': 'models', 'who': 'kimi',
            'ms': swK.elapsedMilliseconds, 'ok': false, 'vpn': vpnK});
        var m = e.toString();
        if (m.length > 60) m = m.substring(0, 60);
        _modelsErr += 'Kimi: $m; ';
      }
    }
    if (_dsKey.isNotEmpty) {
      var swD = Stopwatch()..start();
      final vpnD = await _vpnActive();
      try {
        _dsInfo = await one(_dsBase, _dsKey);
        got++;
        _connInfo += 'DeepSeek ✓ ${swD.elapsedMilliseconds}мс';
        _logReq({'type': 'models', 'who': 'deepseek',
            'ms': swD.elapsedMilliseconds, 'ok': true, 'vpn': vpnD});
      } catch (e) {
        _logError('models-ds', e.toString());
        _logReq({'type': 'models', 'who': 'deepseek',
            'ms': swD.elapsedMilliseconds, 'ok': false, 'vpn': vpnD});
        var m = e.toString();
        if (m.length > 60) m = m.substring(0, 60);
        _modelsErr += 'DS: $m; ';
      }
    }
    _modelsSrc = got > 0 ? 'с сервера' : 'встроенный список';
  }

  Future<String> _testEndpoint(String name, String base, String key) async {
    if (key.isEmpty) return '$name: нет ключа';
    final sw = Stopwatch()..start();
    try {
      final r = await http.get(Uri.parse('$base/models'), headers: {
        'Authorization': 'Bearer $key',
        'Accept-Encoding': 'gzip',
      }).timeout(const Duration(seconds: 10));
      sw.stop();
      if (r.statusCode == 200) {
        return '$name: ✓ ${sw.elapsedMilliseconds} мс';
      }
      return '$name: ✗ HTTP ${r.statusCode} (${sw.elapsedMilliseconds} мс)';
    } catch (e) {
      sw.stop();
      var msg = e.toString();
      if (msg.length > 80) msg = msg.substring(0, 80);
      return '$name: ✗ $msg';
    }
  }

  Widget _modelDropdown(String label, String value,
      List<Map<String, dynamic>> info, List<String> fallback,
      void Function(String) onChanged) {
    final ids = info.isNotEmpty
        ? info.map((e) => e['id'] as String).toList()
        : List<String>.from(fallback);
    if (!ids.contains(value)) ids.insert(0, value);
    String sub(String id) {
      final e = info.firstWhere((x) => x['id'] == id,
          orElse: () => <String, dynamic>{});
      if (e.isNotEmpty) {
        return _metaStr(
            (e['ctx'] as num).toInt(), e['reasoning'] == true, e['vision'] == true);
      }
      final m = _modelMeta(id);
      return _metaStr(m['ctx'], m['reasoning'], m['vision']);
    }

    return DropdownButtonFormField<String>(
      isExpanded: true,
      value: value,
      decoration: InputDecoration(labelText: label, isDense: true),
      selectedItemBuilder: (ctx) => ids
          .map((id) => Text(id,
              style: const TextStyle(fontSize: 14),
              overflow: TextOverflow.ellipsis))
          .toList(),
      items: ids
          .map((id) => DropdownMenuItem(
                value: id,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(id, style: const TextStyle(fontSize: 14)),
                    Text(sub(id),
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  // ---------- Отправка ----------

  void _send(String text, String target) {
    if (text.trim().isEmpty) return;
    setState(() {
      _history.add({'role': 'user', 'content': text, 'time': _now()});
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
    _persistState();
    _scrollBottom();
  }

  void _clearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🗑 Очистить всё?'),
        content: const Text('История, очереди и резюме будут удалены.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _history.clear();
                _inboxKimi.clear();
                _inboxDs.clear();
                _historySummary = '';
                _step = 0;
                _status = '';
              });
              _logLine('🗑 Очистка: история, очереди, резюме стёрты');
              _persistState();
              Navigator.pop(ctx);
            },
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
  }

  List<Map<String, String>> _buildMsgs(String who) {
    final msgs = <Map<String, String>>[];
    msgs.add({
      'role': 'system',
      'content': who == 'kimi'
          ? 'Ты — креативный генератор идей. Отвечай по-русски.'
          : 'Ты — критический аналитик. Отвечай по-русски.'
    });

    final conv = <Map<String, String>>[];
    for (final h in _history) {
      final r = h['role'] as String;
      var c = h['content'] as String;
      if (c.trim().isEmpty || c == '…' || c.startsWith('💭')) continue;
      final cut = c.indexOf('\n\n⚠️ (');
      if (cut > 0) c = c.substring(0, cut);
      if (r == 'user') {
        conv.add({'role': 'user', 'content': c});
      } else if (r == 'kimi' && who == 'kimi') {
        conv.add({'role': 'assistant', 'content': c});
      } else if (r == 'ds' && who == 'ds') {
        conv.add({'role': 'assistant', 'content': c});
      } else if (r == 'kimi' && who == 'ds') {
        conv.add({'role': 'user', 'content': '[Kimi]: $c'});
      } else if (r == 'ds' && who == 'kimi') {
        conv.add({'role': 'user', 'content': '[DeepSeek]: $c'});
      }
    }

    switch (_keepStrategy) {
      case 'last20':
        msgs.addAll(conv.length > 20 ? conv.sublist(conv.length - 20) : conv);
        break;
      case 'smart':
        if (_historySummary.isNotEmpty) {
          msgs.add({
            'role': 'user',
            'content': '[Резюме предыдущего диалога]: $_historySummary'
          });
        }
        msgs.addAll(conv.length > 10 ? conv.sublist(conv.length - 10) : conv);
        break;
      default:
        msgs.addAll(conv);
    }
    return msgs;
  }

  Future<void> _compressIfNeeded(
      String who, List<Map<String, String>> msgs) async {
    final model = who == 'kimi' ? _kimiModel : _dsModel;
    final limit = _contextLimit(model);
    final est = _estTokens(msgs);
    if (est < limit * 0.9) return;

    if (mounted) {
      setState(() => _status =
          '🗜 Контекст ~$est из $limit токенов (>90%) — сжимаю историю…');
    }
    try {
      final url = who == 'kimi' ? _kimiUrl : _dsUrl;
      final key = who == 'kimi' ? _kimiKey : _dsKey;
      final text = _history
          .map((h) => '${h['role']}: ${h['content']}')
          .join('\n')
          .replaceAll(RegExp(r'\n\n⚠️ \([^\n]*'), '');
      final resp = await http
          .post(Uri.parse(url),
              headers: {
                'Authorization': 'Bearer $key',
                'Content-Type': 'application/json; charset=utf-8',
                'Accept-Encoding': 'gzip',
              },
              body: jsonEncode({
                'model': model,
                'messages': [
                  {
                    'role': 'user',
                    'content':
                        'Сожми этот диалог в 2–3 предложения: что обсуждали, какие решения приняты. '
                            'Код и схемы перечисли отдельно списком, не сокращая.\n\n$text'
                  }
                ],
                'max_tokens': 1000,
              }))
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode == 200) {
        final d = jsonDecode(utf8.decode(resp.bodyBytes));
        final s = d['choices']?[0]?['message']?['content']?.toString() ?? '';
        if (s.isNotEmpty) {
          setState(() {
            _historySummary = s;
            _keepStrategy = 'smart';
            _history.add({'role': 'sys', 'content': '🗜 История сжата в резюме'});
            _status = '';
          });
          _saveSettings();
          _persistState();
        }
      }
    } catch (e) {
      _logError('compress', e.toString());
      if (mounted) {
        setState(() => _status = '⚠️ Сжатие не удалось, продолжаю как есть');
      }
    }
  }

  // ---------- Потоковый запрос с метриками ----------

  Future<bool> _vpnActive() async {
    try {
      final ifs = await NetworkInterface.list();
      for (final i in ifs) {
        final n = i.name.toLowerCase();
        if (n.startsWith('tun') || n.startsWith('wg') || n.startsWith('ppp')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<String> _apiOnce(String url, String key, String model,
      List<Map<String, String>> msgs, void Function(String) onChunk,
      Map<String, dynamic> metrics) async {
    final client = http.Client();
    final isKimi = url.contains('moonshot');
    String finishReason = '';
    Map<String, dynamic>? usage;
    final buf = StringBuffer();
    final thinkBuf = StringBuffer();
    var broken = false;
    var chunks = 0;
    DateTime? firstChunkAt;
    final startedAt = DateTime.now();
    final thinkingModel = model.startsWith('kimi-k3') ||
        model.startsWith('kimi-k2.7') ||
        model.startsWith('kimi-k2.6') ||
        model.contains('thinking') ||
        model.contains('reasoner');
    var effTimeout = _timeoutSec;
    if (thinkingModel && effTimeout < 300) effTimeout = 300;
    if (thinkingModel && _reasoningEffort == 'high' && effTimeout < 600) {
      effTimeout = 600;
    }
    if (effTimeout < 60) effTimeout = 60;

    try {
      final request = http.Request('POST', Uri.parse(url));
      request.headers['Authorization'] = 'Bearer $key';
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';
      request.headers['Accept-Encoding'] = 'gzip';
      request.headers['Connection'] = 'keep-alive';
      request.headers['User-Agent'] = 'ai_dialog/$_appVersion';

      final body = <String, dynamic>{
        'model': model,
        'messages': msgs,
        'stream': true,
        'stream_options': {'include_usage': true},
      };
      if (isKimi) {
        body['max_completion_tokens'] = _maxTokens;
        if (_reasoningEffort != 'default' && thinkingModel) {
          body['reasoning_effort'] = _reasoningEffort;
        }
      } else {
        body['max_tokens'] = _maxTokens;
      }
      request.body = jsonEncode(body);
      metrics['params'] = {
        'max_tokens': _maxTokens,
        'effort': body['reasoning_effort'] ?? 'default',
        'hist_msgs': msgs.length,
        'est_tokens': _estTokens(msgs),
      };

      final response =
          await client.send(request).timeout(Duration(seconds: effTimeout));

      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        final short =
            errBody.length > 300 ? '${errBody.substring(0, 300)}…' : errBody;
        metrics['http'] = response.statusCode;
        throw 'HTTP ${response.statusCode}: $short';
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(Duration(seconds: effTimeout));

      try {
        await for (final rawLine in lines) {
          final line = rawLine.trim();
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') break;
          try {
            final j = jsonDecode(data);
            if (j['model'] != null) metrics['srv_model'] = j['model'];
            if (j['usage'] != null) {
              usage = Map<String, dynamic>.from(j['usage']);
            }
            final choice = j['choices']?[0];
            final delta = choice?['delta'];
            final fr = choice?['finish_reason'];
            if (fr != null) finishReason = fr.toString();
            if (delta != null) {
              final rc = delta['reasoning_content'];
              final c = delta['content'];
              if (rc != null || c != null) {
                chunks++;
                firstChunkAt ??= DateTime.now();
              }
              if (rc != null) thinkBuf.write(rc);
              if (c != null) buf.write(c);
              if (buf.isNotEmpty) {
                onChunk(buf.toString());
              } else if (thinkBuf.isNotEmpty && _showThinking) {
                final t = thinkBuf.toString();
                final tail =
                    t.length > 500 ? '…${t.substring(t.length - 500)}' : t;
                onChunk('💭 $tail');
              }
            }
          } catch (_) {}
        }
      } catch (e) {
        if (buf.isNotEmpty || thinkBuf.isNotEmpty) {
          broken = true;
          metrics['broken'] = e.toString();
        } else {
          rethrow;
        }
      }
    } finally {
      client.close();
    }

    metrics['first_ms'] =
        firstChunkAt?.difference(startedAt).inMilliseconds ?? -1;
    metrics['total_ms'] = DateTime.now().difference(startedAt).inMilliseconds;
    metrics['chunks'] = chunks;
    metrics['finish'] = finishReason.isEmpty ? null : finishReason;
    metrics['broken_flag'] = broken;
    if (usage != null) {
      metrics['in'] = usage!['prompt_tokens'];
      metrics['out'] = usage!['completion_tokens'];
      final ct = usage!['completion_tokens_details'];
      if (ct is Map && ct['reasoning_tokens'] != null) {
        metrics['think'] = ct['reasoning_tokens'];
      }
    }

    if (usage != null && mounted) {
      final lim = _contextLimit(model);
      final pt = usage!['prompt_tokens'] ?? 0;
      final pct = lim > 0 ? (100 * pt / lim).toStringAsFixed(0) : '?';
      setState(() => _status =
          '📊 вх $pt / вых ${usage!['completion_tokens'] ?? '?'}'
          '${metrics['think'] != null ? ' (разм: ${metrics['think']})' : ''}'
          ' · контекст $pct% · 1й токен ${metrics['first_ms']}мс');
    }

    var result = buf.toString();

    if (result.trim().isEmpty) {
      final thought = thinkBuf.length;
      if (broken && thought > 0) {
        final how = metrics['broken'].toString().contains('TimeoutException')
            ? 'тишина в потоке дольше таймаута — модель замолчала на середине'
            : 'соединение разорвано извне (сервер или VPN)';
        throw 'Размышления прерваны ($thought симв.): $how. '
            'Параметры запроса ни при чём — проверьте сеть/VPN, смените сервер.';
      }
      throw 'Пустой ответ (finish_reason: ${finishReason.isEmpty ? "нет" : finishReason}'
          '${thought > 0 ? ", размышлений: $thought симв." : ""}'
          '${usage != null ? ", usage: $usage" : ""})';
    }

    if (broken) {
      final how = (metrics['broken'] ?? '').toString().contains('TimeoutException')
          ? 'тишина в потоке'
          : 'соединение разорвано извне';
      result += '\n\n⚠️ ($how — ответ неполный)';
    } else if (finishReason == 'length') {
      result +=
          '\n\n⚠️ (ответ обрезан по лимиту $_maxTokens токенов — увеличьте в настройках)';
    }
    return result;
  }

  int _retryAfterSec(String err) {
    final m = RegExp(r'after (\d+) second').firstMatch(err);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    return 0;
  }

  Future<String> _apiStream(String url, String key, String model,
      List<Map<String, String>> msgs, void Function(String) onChunk) async {
    const maxAttempts = 4;
    final id = ++_reqSeq;
    var attempt = 0;
    final metrics = <String, dynamic>{'id': id, 'model': model, 'url': url};
    metrics['vpn'] = await _vpnActive();
    while (true) {
      attempt++;
      try {
        final r = await _apiOnce(url, key, model, msgs, onChunk, metrics);
        metrics['ok'] = true;
        metrics['retry'] = attempt - 1;
        _logReq(metrics);
        return r;
      } catch (e) {
        final err = e.toString();
        metrics['error'] = err.length > 200 ? err.substring(0, 200) : err;
        final isTimeout = err.contains('TimeoutException');
        final noRetry = (isTimeout && attempt >= 2) ||
            err.startsWith('HTTP 400') ||
            err.startsWith('HTTP 401') ||
            err.startsWith('HTTP 403') ||
            err.startsWith('HTTP 404') ||
            err.startsWith('Пустой ответ') ||
            err.startsWith('Размышления прерваны');
        if (noRetry || attempt >= maxAttempts) {
          metrics['ok'] = false;
          metrics['retry'] = attempt - 1;
          _logReq(metrics);
          rethrow;
        }

        var wait = _retryAfterSec(err);
        if (wait <= 0) wait = 2 * attempt;
        if (wait > 30) wait = 30;
        if (mounted) {
          setState(() => _status =
              '⏳ Сбой без данных, повтор $attempt/$maxAttempts через ${wait}с…');
        }
        await Future.delayed(Duration(seconds: wait));
        if (mounted) setState(() => _status = '');
      }
    }
  }

  // ---------- Вызовы моделей ----------

  Future<void> _callModel({
    required String who,
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
            'content':
                '⚠️ Нет сообщений для ${who == 'kimi' ? 'Kimi' : 'DeepSeek'}'
          }));
      return;
    }
    final msgs = _buildMsgs(who);
    await _compressIfNeeded(who, msgs);
    final finalMsgs = _buildMsgs(who);

    final step = ++_step;
    final sw = Stopwatch()..start();
    var firstChunk = false;
    final waitTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!firstChunk && mounted) {
        setState(() => _status =
            '🧠 $who: жду первый токен… ${t.tick}с ($model'
            '${_reasoningEffort != 'default' ? ', effort=$_reasoningEffort' : ''})');
      }
    });
    setState(() {
      _loading = true;
      _status = '';
      _history.add(
          {'role': who, 'content': '…', 'time': _now(), 'step': '$step'});
    });
    final idx = _history.length - 1;
    _scrollBottom();
    try {
      final r = await _apiStream(url, key, model, finalMsgs, (partial) {
        firstChunk = true;
        if (mounted) {
          setState(() {
            _history[idx]['content'] = partial;
            if (_status.startsWith('🧠')) _status = '';
          });
        }
      });
      sw.stop();
      setState(() {
        inbox.removeAt(0);
        _history[idx]['content'] = r;
        _history[idx]['secs'] = '${sw.elapsed.inSeconds}';
        otherInbox.add(r);
      });
      _persistState();
      _scrollBottom();
    } catch (e) {
      sw.stop();
      setState(() {
        if (idx < _history.length) _history.removeAt(idx);
        _autoLoop = false;
      });
      _persistState();
      final whoName = who == 'kimi' ? 'Kimi' : 'DeepSeek';
      _showErrorDialog(
          whoName, e.toString(), () => who == 'kimi' ? _callKimi() : _callDs());
    }
    waitTimer.cancel();
    if (mounted && _status.startsWith('🧠')) setState(() => _status = '');
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

  // ---------- Диалог ошибки ----------

  void _showErrorDialog(String who, String error, VoidCallback onRetry) {
    if (!mounted) return;
    final tc = TextEditingController(text: _maxTokens.toString());
    String eff = _reasoningEffort;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('⚠️ Ошибка: $who'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(error, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(
                  controller: tc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Лимит токенов', isDense: true),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _efforts.contains(eff) ? eff : _efforts.first,
                  decoration: const InputDecoration(
                      labelText: 'Глубина размышлений', isDense: true),
                  items: _efforts
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setD(() => eff = v ?? eff),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '$who: $error'));
              },
              child: const Text('Копировать'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _maxTokens = int.tryParse(tc.text) ?? _maxTokens;
                  _reasoningEffort = eff;
                });
                _saveSettings();
                Navigator.pop(ctx);
                onRetry();
              },
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Авто-диалог ----------

  Future<void> _auto() async {
    if (_autoLoop) {
      setState(() => _stopRequested = true);
      return;
    }
    if (_inboxKimi.isEmpty && _inboxDs.isEmpty) {
      _send('Начни диалог.', 'kimi');
    }
    setState(() {
      _autoLoop = true;
      _stopRequested = false;
      _awaitingComment = false;
    });
    while (_autoLoop && mounted && !_stopRequested) {
      if (_inboxKimi.isNotEmpty) {
        await _callKimi();
      } else if (_inboxDs.isNotEmpty) {
        await _callDs();
      } else {
        break;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    if (mounted) {
      setState(() {
        _autoLoop = false;
        _awaitingComment =
            _stopRequested && (_inboxKimi.isNotEmpty || _inboxDs.isNotEmpty);
      });
    }
  }

  void _resumeWithComment() {
    final c = _ctrl.text.trim();
    setState(() => _awaitingComment = false);
    if (c.isNotEmpty) _send(c, 'both');
    _auto();
  }

  void _scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ---------- Настройки ----------

  Future<void> _settingsDialog() async {
    setState(() => _status = '📡 Запрашиваю список моделей…');
    await _fetchModelsLists();
    if (mounted) setState(() => _status = '');
    if (!mounted) return;

    final kc = TextEditingController(text: _kimiKey);
    final dc = TextEditingController(text: _dsKey);
    final mc = TextEditingController(text: _maxTokens.toString());
    final tc = TextEditingController(text: _timeoutSec.toString());
    String testK = '';
    String testD = '';
    String km = _kimiModel;
    String dm = _dsModel;
    String eff = _reasoningEffort;
    String strat = _keepStrategy;
    bool showThink = _showThinking;
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
                _modelDropdown('Модель Kimi', km, _kimiInfo, _kimiModels,
                    (v) => setD(() => km = v)),
                const SizedBox(height: 8),
                _modelDropdown('Модель DeepSeek', dm, _dsInfo, _dsModels,
                    (v) => setD(() => dm = v)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Список моделей: $_modelsSrc\n$_connInfo${_modelsErr.isEmpty ? '' : '\n⚠️ $_modelsErr'}',
                      style:
                          const TextStyle(fontSize: 10, color: Colors.grey)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.network_check, size: 16),
                        label: const Text('Проверить соединение',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () async {
                          setD(() {
                            testK = 'Kimi: …';
                            testD = 'DeepSeek: …';
                          });
                          final k = await _testEndpoint(
                              'Kimi', _kimiBase, kc.text.trim());
                          setD(() => testK = k);
                          final d = await _testEndpoint(
                              'DeepSeek', _dsBase, dc.text.trim());
                          setD(() => testD = d);
                        },
                      ),
                    ),
                  ],
                ),
                if (testK.isNotEmpty || testD.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('$testK\n$testD',
                        style: const TextStyle(fontSize: 12)),
                  ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _efforts.contains(eff) ? eff : _efforts.first,
                  decoration: const InputDecoration(
                      labelText: 'Глубина размышлений (Kimi)'),
                  items: _efforts
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setD(() => eff = v ?? eff),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _strategies.contains(strat) ? strat : 'smart',
                  decoration:
                      const InputDecoration(labelText: 'Стратегия истории'),
                  items: const [
                    DropdownMenuItem(
                        value: 'smart',
                        child: Text('smart — резюме + последние 10')),
                    DropdownMenuItem(
                        value: 'last20', child: Text('last20 — последние 20')),
                    DropdownMenuItem(
                        value: 'full',
                        child: Text('full — вся (не рекоменд.)')),
                  ],
                  onChanged: (v) => setD(() => strat = v ?? strat),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: mc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Лимит токенов ответа'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Таймаут паузы потока, сек'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Показывать ход размышлений',
                      style: TextStyle(fontSize: 14)),
                  value: showThink,
                  onChanged: (v) => setD(() => showThink = v),
                ),
                const SizedBox(height: 8),
                Text('Версия приложения: $_appVersion',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _kimiKey = kc.text.trim();
                  _dsKey = dc.text.trim();
                  _kimiModel = km;
                  _dsModel = dm;
                  _reasoningEffort = eff;
                  _keepStrategy = strat;
                  _maxTokens = int.tryParse(mc.text) ?? _maxTokens;
                  _timeoutSec = int.tryParse(tc.text) ?? _timeoutSec;
                  _showThinking = showThink;
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

  // ---------- Экраны ----------

  void _openQueues() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QueueScreen(
          inboxKimi: _inboxKimi,
          inboxDs: _inboxDs,
          onChanged: () {
            setState(() {});
            _persistState();
          },
        ),
      ),
    );
  }

  void _openErrorLog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ErrorLogScreen(log: _errorLog)),
    );
  }

  // ---------- UI ----------

  Color _color(String r) {
    if (r == 'user') return const Color(0xFF58A6FF);
    if (r == 'kimi') return const Color(0xFFF0883E);
    if (r == 'ds') return const Color(0xFF3FB950);
    return Colors.grey;
  }

  String _label(Map<String, String> m) {
    final r = m['role'] as String;
    var base = switch (r) {
      'user' => '👤 Вы',
      'kimi' => '🔥 Kimi ($_kimiModel)',
      'ds' => '🧊 DeepSeek ($_dsModel)',
      _ => '⚙️ Система',
    };
    final step = m['step'];
    final secs = m['secs'];
    final tm = m['time'];
    if (step != null) base += ' · шаг $step';
    if (secs != null) base += ' · ${secs}с';
    if (tm != null) base += ' · $tm';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final fs = MediaQuery.of(context).size.width * 0.032;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 Kimi ↔ DeepSeek', style: TextStyle(fontSize: 15)),
        actions: [
          IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Очистить всё',
              onPressed: _clearAll),
          IconButton(
              icon: const Icon(Icons.bug_report, size: 20),
              onPressed: _openErrorLog),
          IconButton(
              icon: const Icon(Icons.settings), onPressed: _settingsDialog),
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
                    onPressed: _auto,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _autoLoop
                            ? Colors.red.shade700
                            : Colors.blue.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: Text(_autoLoop ? '⏹ Стоп' : '⏩ Auto',
                        style: TextStyle(fontSize: fs)),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(_status,
                  style: const TextStyle(fontSize: 12, color: Colors.amber)),
            ),
          if (_awaitingComment)
            Container(
              color: const Color(0xFF2D2404),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                        '⏸ Цикл остановлен. Напишите комментарий и продолжите:',
                        style: TextStyle(fontSize: 12, color: Colors.amber)),
                  ),
                  ElevatedButton(
                    onPressed: _resumeWithComment,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 12)),
                    child: const Text('▶ Продолжить',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(6),
              itemCount: _history.length,
              itemBuilder: (ctx, i) {
                final m = _history[i];
                final r = m['role'] as String;
                final c = m['content'] as String;
                final thinking = c.startsWith('💭');
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
                      Text(_label(m),
                          style: TextStyle(
                              fontSize: fs * 0.75,
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.bold)),
                      SelectableText(
                        c,
                        style: TextStyle(
                          fontSize: thinking ? fs * 0.85 : fs,
                          height: 1.2,
                          color: thinking ? Colors.grey.shade400 : null,
                          fontStyle:
                              thinking ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
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
                      hintText: _awaitingComment
                          ? 'Комментарий к диалогу...'
                          : 'To $_target...',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (t) => _awaitingComment
                        ? _resumeWithComment()
                        : _send(t, _target),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () => _awaitingComment
                      ? _resumeWithComment()
                      : _send(_ctrl.text, _target),
                  icon: const Icon(Icons.send, color: Color(0xFF58A6FF)),
                  iconSize: 22,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('v$_appVersion',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
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

/// Экран журнала запросов и ошибок с копированием.
class ErrorLogScreen extends StatelessWidget {
  final List<String> log;
  const ErrorLogScreen({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🐞 Журнал (${log.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Копировать всё',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Журнал скопирован')));
            },
          ),
        ],
      ),
      body: log.isEmpty
          ? const Center(
              child:
                  Text('Пока пусто', style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: log.length,
              itemBuilder: (ctx, i) => Card(
                color: const Color(0xFF1F2937),
                margin: const EdgeInsets.only(bottom: 4),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(log[log.length - 1 - i],
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
    );
  }
}
