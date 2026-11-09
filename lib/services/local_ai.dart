import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/insights.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';

/// Advice from a language model that runs on this computer (Ollama).
///
/// REBOOT talks only to a loopback address; any other host is refused, so
/// usage data cannot leave the device through this feature. Only a short
/// summary is sent: daily totals, top apps, goal, streak, peak hours.
class LocalAiAssistant {
  LocalAiAssistant({Uri? endpoint, HttpClient Function()? httpClient})
    : endpoint = endpoint ?? Uri.parse('http://127.0.0.1:11434'),
      _client = httpClient ?? HttpClient.new {
    if (!isLoopback(this.endpoint)) {
      throw ArgumentError.value(
        this.endpoint,
        'endpoint',
        'Only a local (loopback) address is allowed.',
      );
    }
  }

  final Uri endpoint;
  final HttpClient Function() _client;

  static bool isLoopback(Uri uri) {
    if (uri.scheme != 'http') return false;
    // A literal loopback IP only: `localhost` can resolve elsewhere.
    final address = InternetAddress.tryParse(uri.host);
    return address != null && address.isLoopback;
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .openUrl(method, endpoint.replace(path: path))
          .timeout(timeout);
      // Never follow a redirect away from the loopback address.
      request.followRedirects = false;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw LocalAiException(
          'Ollama ответила с кодом ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const LocalAiException('Неожиданный ответ локальной модели.');
      }
      return decoded;
    } on LocalAiException {
      rethrow;
    } on TimeoutException {
      throw const LocalAiException('Локальная модель не ответила вовремя.');
    } on SocketException {
      throw const LocalAiException(
        'Ollama не найдена на этом компьютере (127.0.0.1:11434).',
      );
    } on Object catch (error) {
      throw LocalAiException(
        'Не удалось связаться с локальной моделью: $error',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Installed models, e.g. `llama3.2:3b`. Throws when Ollama is not running.
  Future<List<String>> models() async {
    final data = await _json('GET', '/api/tags');
    final models = data['models'];
    if (models is! List) return const [];
    return [
      for (final m in models)
        if (m is Map && m['name'] is String) m['name'] as String,
    ];
  }

  Future<String> advise({
    required String model,
    required String summary,
  }) async {
    final data = await _json(
      'POST',
      '/api/generate',
      timeout: const Duration(seconds: 120),
      body: {
        'model': model,
        'prompt': '$_instructions\n\nДанные пользователя:\n$summary',
        'stream': false,
        'options': {'temperature': 0.4},
      },
    );
    final text = data['response'];
    if (text is! String || text.trim().isEmpty) {
      throw const LocalAiException('Модель вернула пустой ответ.');
    }
    return text.trim();
  }

  static const _instructions =
      'Ты помощник в приложении цифрового благополучия REBOOT. По данным '
      'экранного времени дай 3 коротких практичных совета на русском. '
      'Опирайся только на приведённые цифры и называй их. Не ставь диагнозов, '
      'не говори о зависимости, здоровье или дофамине, не осуждай и не пугай. '
      'Не выдумывай данных, которых нет. Формат: нумерованный список, '
      'каждый пункт не длиннее двух предложений.';
}

class LocalAiException implements Exception {
  const LocalAiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The only data the model sees. No sessions, titles or content.
String buildAiSummary({
  required UsageReport week,
  required StreakSummary streak,
  ActivityHeatmap? heatmap,
}) {
  final lines = <String>[
    'Режим: ${week.mode == UsageDataMode.demo ? 'демонстрационные данные' : 'данные устройства'}.',
    'Дневная цель: ${formatMinutes(week.goalMinutes)}.',
    'Дней с данными: ${week.daysWithData.length} из ${week.periodDays}.',
    'Среднее экранное время в день: ${formatDuration(week.averageActiveSeconds)}.',
    'Дней в пределах цели: ${week.daysWithinGoal}.',
    if (week.changeFraction != null)
      'Изменение к прошлой неделе: ${week.changeFraction! < 0 ? '−' : '+'}${formatPercent(week.changeFraction!.abs())}.',
    'Серия дней в пределах цели: текущая ${streak.current}, лучшая ${streak.best}.',
    'По дням: ${[for (final d in week.days) '${weekdayShort(d.day.weekday)} ${d.hasData ? formatDuration(d.activeSeconds) : 'нет данных'}'].join(', ')}.',
  ];
  final apps = (week.appsPeriod ?? week.appsToday).take(5).toList();
  if (apps.isNotEmpty) {
    lines.add(
      'Топ приложений: ${[for (final a in apps) '${a.name} — ${formatDuration(a.activeSeconds)}'].join('; ')}.',
    );
  }
  if (heatmap != null && !heatmap.isEmpty) {
    final hours = heatmap.byHour;
    var peak = 0;
    for (var h = 1; h < 24; h++) {
      if (hours[h] > hours[peak]) peak = h;
    }
    lines.add('Самый активный час: ${hourRange(peak, peak + 1)}.');
  }
  return lines.join('\n');
}

/// Advice without any model: fixed rules over the same facts.
List<String> ruleBasedTips({
  required UsageReport week,
  ActivityHeatmap? heatmap,
}) {
  final tips = <String>[];
  final withData = week.daysWithData.length;
  if (withData < 3) {
    return const [
      'Пока мало данных: оставьте REBOOT работать несколько дней, и советы станут конкретнее.',
    ];
  }
  final goal = week.goalMinutes * 60;
  if (week.averageActiveSeconds > goal) {
    tips.add(
      'В среднем ${formatDuration(week.averageActiveSeconds)} в день — выше вашей цели '
      '${formatMinutes(week.goalMinutes)}. Попробуйте снизить на 15–20 минут, а не сразу до цели.',
    );
  } else {
    tips.add(
      'Среднее ${formatDuration(week.averageActiveSeconds)} укладывается в цель. Если хотите, '
      'сделайте цель чуть строже — серия покажет, получается ли.',
    );
  }
  final apps = week.appsPeriod ?? week.appsToday;
  if (apps.isNotEmpty && week.periodActiveSeconds > 0) {
    final top = apps.first;
    final share = top.activeSeconds / week.periodActiveSeconds;
    if (share >= .3) {
      tips.add(
        '${top.name} занимает ${formatPercent(share)} времени. Если это не основная работа, '
        'поставьте для него цель или мягкое ограничение в разделе «Цели».',
      );
    }
  }
  if (heatmap != null && !heatmap.isEmpty) {
    final hours = heatmap.byHour;
    final late = [
      for (var h = 22; h < 24; h++) hours[h],
      for (var h = 0; h < 2; h++) hours[h],
    ].fold(0, (a, b) => a + b);
    if (late > heatmap.totalSeconds * .1) {
      tips.add(
        'Заметная часть активности приходится на 22:00–02:00. Можно попробовать фокус-сессию '
        'раньше вечером и закрывать компьютер к выбранному времени.',
      );
    }
  }
  if (week.periodIdleSeconds > week.periodActiveSeconds * .3) {
    tips.add(
      'Много времени компьютер включён без ввода. Если это фоновое видео — всё в порядке; '
      'если нет, блокировка экрана помогает делать настоящие перерывы.',
    );
  }
  if (tips.length < 3) {
    tips.add(
      'Фокус-сессия на 25 минут с паузой после неё — простой способ проверить, '
      'как меняется ваш день.',
    );
  }
  return tips.take(3).toList();
}
