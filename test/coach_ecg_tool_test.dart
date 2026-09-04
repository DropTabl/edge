// The coach's `get_ecg_reading` tool: a bound read by id, a bounded min/max
// envelope, and nothing that identifies the band or leaks bytes. Plus the
// prompt and tool-definition pins.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_prompt.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_coach_ecg_tool_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final reading = EcgReading(
      id: 'ecg_tool_1',
      deviceId: 'SERIAL-SECRET',
      wrist: EcgWrist.right,
      startTs: 1787823754,
      endTs: 1787823784,
      strapTerminalTs: 1787823784,
      strapTerminalSubsec: 0,
      resultCode: 1,
      category: EcgCategory.sinusRhythm,
      avgHr: 77,
      quality: 3,
      unreadableMask: 0,
      interruptions: 0,
      sampleCount: 3000,
      minUv: -531,
      maxUv: 731,
      rmsUv: 126.8,
      missingSegments: 1,
      status: EcgReadingStatus.completed,
      notes: 'private note',
      createdAt: 1787823784000,
    );
    // 30 packets of 100 samples with one placeholder; a lone spike so the
    // envelope's max/min survive.
    final packets = <EcgAcceptedPacket>[];
    for (var s = 0; s < 31; s++) {
      if (s == 10) {
        packets.add(EcgAcceptedPacket.placeholder(s));
        continue;
      }
      final samples = Int16List.fromList(
        List.generate(100, (i) => (i % 20) * 10 - 100),
      );
      if (s == 20) samples[50] = 731;
      if (s == 25) samples[7] = -531;
      packets.add(
        EcgAcceptedPacket(
          sequence: s,
          strapSeconds: 1787823754 + s,
          strapSubsec: 0,
          samples: samples,
          inner: Uint8List.fromList(List.filled(228, 0xab)),
        ),
      );
    }
    await LocalDb.insertEcgReading(reading.toRow(), [
      for (final x in packets) EcgPacketCodec.toRow(x),
    ]);
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test(
    'returns the band summary and a bounded envelope; no identity, no bytes',
    () async {
      final out = await CoachActions.ecgReading(
        await LocalDb.instance,
        'ecg_tool_1',
      );
      final j = jsonDecode(out) as Map<String, dynamic>;
      expect(j['id'], 'ecg_tool_1');
      expect(j['band_category'], 'sinusRhythm');
      expect(j['result_code'], 1);
      expect(j['avg_hr'], 77);
      expect(j['duration_s'], 30);
      expect(j['sample_count'], 3000);
      expect(j['missing_segments'], 1);
      expect(j['unit'], kEcgSampleUnit);
      final env = j['waveform_envelope'] as Map<String, dynamic>;
      final pts = env['points'] as List;
      expect(pts.length, lessThanOrEqualTo(CoachActions.ecgEnvelopeBuckets));
      expect(env['buckets'], pts.length);
      expect(
        pts.where((e) => e == null),
        isNotEmpty,
        reason: 'the placeholder second',
      );
      final maxes = pts.whereType<List>().map((e) => e[1] as int);
      final mins = pts.whereType<List>().map((e) => e[0] as int);
      expect(maxes, contains(731), reason: 'peaks survive the downsampling');
      expect(mins, contains(-531));
      expect(out, isNot(contains('SERIAL-SECRET')));
      expect(out, isNot(contains('private note')));
      expect(out, isNot(contains('abab')));
      expect(out, isNot(contains('device_id')));
      expect(
        out.length,
        lessThan(CoachEngine.kMaxToolResultChars),
        reason: 'fits one tool result without truncation',
      );
    },
  );

  test('an unknown id is an error, an empty id is a usage error', () async {
    final out = await CoachActions.ecgReading(await LocalDb.instance, 'nope');
    expect(jsonDecode(out), containsPair('error', contains('nope')));
    final db = await LocalDb.instance;
    await expectLater(
      () => CoachActions.ecgReading(db, ''),
      throwsA(isA<CoachActionError>()),
    );
  });

  test('the envelope is deterministic and never averages a bucket', () {
    // 8 samples into 3 buckets: [0,2) [2,5) [5,8) — floors, deterministic.
    final env = CoachActions.ecgEnvelope([1, 9, -4, null, null, 2, 2, 2], 3);
    expect(env, [
      [1, 9],
      [-4, -4],
      [2, 2],
    ]);
    // A bucket that is entirely missing is null, not zero.
    expect(CoachActions.ecgEnvelope([5, null, null, 7], 2), [
      [5, 5],
      [7, 7],
    ]);
    expect(CoachActions.ecgEnvelope([null, null, 3, 4], 2), [
      null,
      [3, 4],
    ]);
    expect(CoachActions.ecgEnvelope(const [], 300), isEmpty);
    expect(CoachActions.ecgEnvelope([5], 300), [
      [5, 5],
    ]);
  });

  test('the system prompt carries the ECG law and the tool', () {
    expect(kCoachSystemPrompt, contains('get_ecg_reading'));
    expect(kCoachSystemPrompt, contains('v_ecg_readings'));
    expect(kCoachSystemPrompt, contains('HeartKey'));
    expect(kCoachSystemPrompt, contains('must NOT'));
    expect(kCoachSystemPrompt, contains('Not medical advice'));
    expect(kCoachSystemPrompt.toLowerCase(), contains('polarity'));
    expect(kCoachSystemPrompt.toLowerCase(), contains('emergency'));
  });
}
