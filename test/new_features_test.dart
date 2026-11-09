import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/app_goal.dart';
import 'package:reboot_app/models/collector_models.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/services/local_ai.dart';
import 'package:reboot_app/theme/reboot_themes.dart';
import 'package:reboot_app/widgets/streak_widgets.dart';

const today = LocalDay(2026, 11, 5);
DateTime at(int daysAgo, int hour, [int minute = 0]) {
  final d = today.addDays(-daysAgo);
  return DateTime(d.year, d.month, d.day, hour, minute);
}

HistoryIndex withUsage({required String app, required int minutes}) =>
    HistoryIndex(
      sessions: [
        AppSession(
          appId: app,
          appName: app,
          start: at(0, 10),
          end: at(0, 10).add(Duration(minutes: minutes)),
        ),
      ],
      launches: const [],
      intervals: [
        TimeInterval(
          kind: IntervalKind.coverage,
          start: at(0, 0),
          end: at(0, 23),
        ),
      ],
    );

void main() {
  group('REBOOT is not part of its own statistics', () {
    test('ingestor drops REBOOT sessions and launches', () {
      final batch = EventIngestor().ingest(
        CollectorSnapshot(
          platform: CollectorPlatform.macOS,
          capturedAt: at(0, 12),
          events: [
            UsageEvent(
              type: UsageEventType.foregroundEnded,
              timestamp: at(0, 11),
              appIdentifier: 'com.reboot.app.rebootApp',
              durationSeconds: 600,
            ),
            UsageEvent(
              type: UsageEventType.appLaunched,
              timestamp: at(0, 11),
              appIdentifier: 'reboot_app.exe',
            ),
            UsageEvent(
              type: UsageEventType.foregroundEnded,
              timestamp: at(0, 11, 30),
              appIdentifier: 'com.apple.Safari',
              durationSeconds: 60,
            ),
          ],
        ),
      );
      expect(batch.sessions.map((s) => s.appId), ['com.apple.Safari']);
      expect(batch.launches, isEmpty);
    });

    test('already stored REBOOT time is ignored by reports', () {
      final index = HistoryIndex(
        sessions: [
          AppSession(
            appId: 'com.reboot.app.rebootApp',
            appName: 'REBOOT',
            start: at(0, 9),
            end: at(0, 10),
          ),
        ],
        launches: const [],
        intervals: const [],
      );
      expect(index.day(today).activeSeconds, 0);
      expect(index.apps(today, today), isEmpty);
    });
  });

  group('soft limits', () {
    final goal = AppGoal(
      appId: 'tv',
      appName: 'TV',
      dailyLimitMinutes: 30,
      softLimit: true,
      createdAt: DateTime.utc(2026, 11, 1),
    );

    test('apply only when the limit is used up', () {
      final now = at(0, 12);
      expect(
        exhaustedSoftLimits(
          goals: [goal],
          index: withUsage(app: 'tv', minutes: 20),
          today: today,
          now: now,
        ),
        isEmpty,
      );
      expect(
        exhaustedSoftLimits(
          goals: [goal],
          index: withUsage(app: 'tv', minutes: 31),
          today: today,
          now: now,
        ),
        [goal],
      );
    });

    test('snooze and release for today are respected', () {
      final index = withUsage(app: 'tv', minutes: 45);
      final now = at(0, 12);
      expect(
        exhaustedSoftLimits(
          goals: [goal],
          index: index,
          today: today,
          now: now,
          snoozedUntil: {'tv': now.add(const Duration(minutes: 5))},
        ),
        isEmpty,
      );
      expect(
        exhaustedSoftLimits(
          goals: [goal],
          index: index,
          today: today,
          now: now.add(const Duration(minutes: 6)),
          snoozedUntil: {'tv': now.add(const Duration(minutes: 5))},
        ),
        [goal],
      );
      expect(
        exhaustedSoftLimits(
          goals: [goal],
          index: index,
          today: today,
          now: now,
          releasedToday: {'tv'},
        ),
        isEmpty,
      );
    });

    test(
      'goals without soft limit are never enforced; old files default off',
      () {
        final reminderOnly = goal.copyWith(softLimit: false);
        expect(
          exhaustedSoftLimits(
            goals: [reminderOnly],
            index: withUsage(app: 'tv', minutes: 90),
            today: today,
            now: at(0, 12),
          ),
          isEmpty,
        );
        final old = goal.toMap()..remove('softLimit');
        expect(AppGoal.fromMap(old).softLimit, isFalse);
        expect(AppGoal.fromMap(goal.toMap()).softLimit, isTrue);
      },
    );
  });

  group('local AI', () {
    test('only literal loopback addresses are accepted', () {
      expect(
        LocalAiAssistant.isLoopback(Uri.parse('http://127.0.0.1:11434')),
        isTrue,
      );
      expect(
        LocalAiAssistant.isLoopback(Uri.parse('http://[::1]:11434')),
        isTrue,
      );
      expect(
        LocalAiAssistant.isLoopback(Uri.parse('http://localhost:11434')),
        isFalse,
      );
      expect(
        LocalAiAssistant.isLoopback(Uri.parse('http://192.168.1.5:11434')),
        isFalse,
      );
      expect(
        LocalAiAssistant.isLoopback(Uri.parse('https://example.com')),
        isFalse,
      );
      expect(
        () => LocalAiAssistant(endpoint: Uri.parse('http://10.0.0.2:11434')),
        throwsArgumentError,
      );
    });

    test('talks to a local server and sends only the summary', () async {
      // The test binding fakes every HttpClient with status 400; use a real
      // one against a real loopback server here.
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      addTearDown(() => HttpOverrides.global = previous);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? prompt;
      server.listen((request) async {
        if (request.uri.path == '/api/tags') {
          request.response.write(
            jsonEncode({
              'models': [
                {'name': 'llama3.2:3b'},
              ],
            }),
          );
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          prompt = body['prompt'] as String;
          request.response.write(jsonEncode({'response': '1. Совет'}));
        }
        await request.response.close();
      });
      final ai = LocalAiAssistant(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      expect(await ai.models(), ['llama3.2:3b']);
      final index = withUsage(app: 'com.example.Editor', minutes: 90);
      final week = buildRangeReport(
        index: index,
        from: today.addDays(-6),
        to: today,
        goalMinutes: 120,
      );
      final summary = buildAiSummary(
        week: week,
        streak: StreakSummary.empty(today: today, goalMinutes: 120),
      );
      expect(
        await ai.advise(model: 'llama3.2:3b', summary: summary),
        '1. Совет',
      );
      expect(prompt, contains('com.example.Editor — 1 ч 30 мин'));
      expect(prompt, isNot(contains('T10:00')), reason: 'no raw session times');
    });

    test('missing Ollama gives a clear error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final ai = LocalAiAssistant(
        endpoint: Uri.parse('http://127.0.0.1:$port'),
      );
      expect(ai.models, throwsA(isA<LocalAiException>()));
    });

    test('rule-based tips need data and name the top app', () {
      final empty = buildRangeReport(
        index: HistoryIndex(
          sessions: const [],
          launches: const [],
          intervals: const [],
        ),
        from: today.addDays(-6),
        to: today,
        goalMinutes: 120,
      );
      expect(ruleBasedTips(week: empty).single, contains('мало данных'));
      final busy = HistoryIndex(
        sessions: [
          for (var d = 0; d < 5; d++)
            AppSession(
              appId: 'g',
              appName: 'Game',
              start: at(d, 18),
              end: at(d, 22),
            ),
        ],
        launches: const [],
        intervals: [
          for (var d = 0; d < 5; d++)
            TimeInterval(
              kind: IntervalKind.coverage,
              start: at(d, 0),
              end: at(d, 23),
            ),
        ],
      );
      final tips = ruleBasedTips(
        week: buildRangeReport(
          index: busy,
          from: today.addDays(-6),
          to: today,
          goalMinutes: 120,
        ),
      );
      expect(tips.first, contains('выше вашей цели'));
      expect(tips.any((t) => t.contains('Game')), isTrue);
    });
  });

  testWidgets('streak calendar shows 7 days by default and a month on demand', (
    tester,
  ) async {
    final summary = StreakCalculator.summarize(
      days: [StreakDay(day: today.addDays(-1), minutes: 60, goalMinutes: 120)],
      today: today,
      goalMinutes: 120,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: RebootThemes.build(AppThemeId.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StreakCalendar(summary: summary, mode: UsageDataMode.real),
          ),
        ),
      ),
    );
    expect(find.textContaining('За неделю'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    await tester.tap(find.text('Месяц'));
    await tester.pumpAndSettle();
    expect(find.textContaining('В этом месяце'), findsOneWidget);
    expect(find.text('Ноябрь 2026'), findsOneWidget);
  });
}

class _RealHttp extends HttpOverrides {}
