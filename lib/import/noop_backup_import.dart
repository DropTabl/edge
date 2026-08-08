// noop_backup_import.dart — read a `.noopbak` full backup.
//
// A `.noopbak` is a ZIP around `noop-backup.sqlite`, NOOP's own GRDB database.
// On iOS it is the ONLY export NOOP offers, so every iOS user migrating across
// arrives with one; the raw-sensor CSV this importer originally required is
// Android-only. That is issue #160 for real, rather than the UTF-8 symptom.
//
// WHAT IT HOLDS (measured on a 13-day backup, 260 MB, NOOP 9.x):
//   hrSample(deviceId, ts, bpm)                 1,032,010 rows   1 Hz
//   rrInterval(deviceId, ts, rrMs)                505,358
//   gravitySample(deviceId, ts, x, y, z)        1,031,199        1 Hz
//   skinTempSample(deviceId, ts, raw)           1,031,199        1 Hz
//   stepSample(deviceId, ts, counter)           1,031,199        cumulative
//   spo2Sample / respSample                             0        present, empty
//   sleepSession / dailyMetric / metricSeries          12 / 14 / 24
// Timestamps are epoch SECONDS on a shared 1 Hz grid, which is the same shape as
// our own decoded substrate — so this is a FULL-FIDELITY source, not a summary
// import. We take the raw channels and re-derive; `sleepSession` and
// `dailyMetric` (NOOP's own scores) are deliberately NOT read, because a second
// set of stages and daily numbers would contradict the ones we compute.
//
// TWO TRAPS THIS FILE EXISTS TO AVOID:
//   1. `spo2Sample` and `respSample` are EMPTY in a real backup and a future
//      schema may drop them outright, so every table is probed before it is read.
//   2. deviceId is NOT consistent within one backup — the sample tables carry
//      "my-whoop" while sleepSession carries "my-whoop-noop". Nothing here
//      filters or joins on it: a user who replaced a strap has both ids over
//      disjoint spans and wants BOTH imported, and a per-second map keyed on ts
//      already collapses the (unrealistic) case of two straps worn at once.
//
// MEMORY. 3.6 M rows cannot be materialised, and sqflite serialises a whole
// result set on the platform side before any of it crosses the channel. So we
// walk one LOCAL DAY at a time (the unit [NoopIngest] derives anyway) and read
// each table for that day in pages.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import 'import_container.dart';
import 'noop_import.dart';
import 'noop_ingest.dart';

/// Rows per platform-channel round trip. Big enough that a 1 Hz day is a handful
/// of queries, small enough that no single response is a memory event. Not
/// const: the page-boundary contract below is only testable at a small size.
@visibleForTesting
int kNoopBackupPageRows = 20000;

/// Plausible unix seconds. A timestamp outside this range is corrupt or
/// millisecond-scaled, and letting one into the day walk would march it across
/// decades one day at a time.
const int _kMinPlausibleTs = 1000000000; // 2001-09-09
const int _kMaxPlausibleTs = 4102444800; // 2100-01-01

class NoopBackupImporter {
  /// Import an already-extracted `noop-backup.sqlite` at [path].
  ///
  /// Opened READ-ONLY — a backup is the user's only copy of their history and
  /// this must not be able to write to it, even by accident.
  static Future<NoopImportResult> importDatabase(
    String path,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    if (!await File(path).exists()) {
      throw const ImportFormatException('That backup could not be read.');
    }
    final Database src;
    try {
      src = await openDatabase(path, readOnly: true);
    } catch (e) {
      throw ImportFormatException(
        'That backup\'s database could not be opened ($e). If it came off '
        'another phone, try exporting it again.',
      );
    }
    try {
      return await _import(src, profile, engine, onProgress: onProgress);
    } finally {
      await src.close();
    }
  }

  static Future<NoopImportResult> _import(
    Database src,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    final tables = await _tableNames(src);
    // hrSample is the spine: no heart rate means nothing downstream can be
    // derived, so its absence is a wrong-file error rather than an empty import.
    if (!tables.contains('hrSample')) {
      throw ImportFormatException(
        'That database is not a NOOP backup — it has no `hrSample` table '
        '(found: ${tables.take(6).join(', ')}${tables.length > 6 ? '…' : ''}).',
      );
    }

    final span = await _span(src, tables);
    if (span == null) {
      throw const ImportFormatException(
        'That NOOP backup holds no samples — there is nothing to import.',
      );
    }
    final (minTs, maxTs) = span;

    final ingest = NoopIngest(profile, engine, onProgress: onProgress);

    // Walk LOCAL days. Built through the DateTime(y, m, d + 1) constructor
    // rather than `add(Duration(days: 1))` so a DST boundary lands on real local
    // midnight instead of 23:00 or 01:00.
    var dayStart = _localMidnight(minTs);
    while (dayStart.millisecondsSinceEpoch ~/ 1000 <= maxTs) {
      final next = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
      final from = dayStart.millisecondsSinceEpoch ~/ 1000;
      final to = next.millisecondsSinceEpoch ~/ 1000;

      // Order within a day does not matter — [NoopIngest] rebuilds the Substrate
      // sorted by timestamp — but the DAYS must arrive in ascending order, since
      // the high-water date is what closes out and derives the previous one.
      await _read(src, tables, 'hrSample', ['ts', 'bpm'], from, to, (r) async {
        final ts = _int(r['ts']), v = _int(r['bpm']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.hr(ts, v);
      });
      await _read(src, tables, 'rrInterval', ['ts', 'rrMs'], from, to,
          (r) async {
        final ts = _int(r['ts']), v = _num(r['rrMs']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.rr(ts, v);
      });
      await _read(src, tables, 'gravitySample', ['ts', 'x', 'y', 'z'], from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.gravity(ts, _num(r['x']), _num(r['y']), _num(r['z']));
        }
      });
      await _read(src, tables, 'skinTempSample', ['ts', 'raw'], from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) ingest.skinTemp(ts, _int(r['raw']));
      });
      await _read(src, tables, 'spo2Sample', ['ts', 'red', 'ir'], from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.spo2(ts, _int(r['red']), _int(r['ir']));
        }
      });
      await _read(src, tables, 'stepSample', ['ts', 'counter'], from, to,
          (r) async {
        final ts = _int(r['ts']), v = _int(r['counter']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.stepCounter(ts, v);
      });

      dayStart = next;
    }

    if (ingest.rows == 0) {
      throw const ImportFormatException(
        'That NOOP backup holds no samples we could read.',
      );
    }
    await ingest.finish();
    return NoopImportResult(ingest.days, ingest.rows, ingest.lateRows,
        ingest.steps, ingest.strandedDates);
  }

  /// Page one table's rows for the half-open window [from, to) into [onRow].
  /// A table the backup does not have is skipped — `spo2Sample` and `respSample`
  /// are already absent-in-practice (present but empty), and a future NOOP
  /// schema is free to drop either outright.
  ///
  /// Paged by KEYSET (`ts > last`), not OFFSET: LIMIT/OFFSET re-walks and
  /// re-discards every skipped row, so paging a 86,400-row day turns quadratic.
  ///
  /// `ts` is NOT unique in every table — `rrInterval`'s key is (deviceId, ts,
  /// rrMs), so one second can hold several beats, and two devices can share a
  /// second in any table. A page boundary landing inside such a second would
  /// drop its remaining rows silently, so a FULL page discards its trailing
  /// partial second and re-reads it from the top of the next page.
  static Future<void> _read(
    Database src,
    Set<String> tables,
    String table,
    List<String> cols,
    int from,
    int to,
    Future<void> Function(Map<String, Object?> row) onRow,
  ) async {
    if (!tables.contains(table)) return;
    // The COLUMNS are probed too, not just the table. `spo2Sample` is the one
    // table documented as never seen non-empty, i.e. the one whose column names
    // are least confirmed — and a rename would surface as a raw
    // `no such column` SQL error mid-import, after days had already been
    // written, with `finish()` never reached to roll the rollups forward.
    final have = await _columnNames(src, table);
    final usable = [for (final c in cols) if (have.contains(c)) c];
    if (!usable.contains('ts') || usable.length < cols.length) return;
    var cursor = from - 1;
    while (true) {
      final rows = await src.query(
        table,
        columns: cols,
        where: 'ts > ? AND ts < ?',
        whereArgs: [cursor, to],
        orderBy: 'ts',
        limit: kNoopBackupPageRows,
      );
      if (rows.isEmpty) return;
      final full = rows.length == kNoopBackupPageRows;
      final lastTs = _int(rows.last['ts']);
      // A NULL or non-integer ts in the last row of a page would leave the
      // cursor unmoved and loop forever; take the page and stop instead.
      if (lastTs == null || lastTs <= cursor) {
        for (final r in rows) {
          await onRow(r);
        }
        return;
      }

      // On a full page, hold back the trailing rows that share the last
      // timestamp — the next page re-reads that second whole.
      var end = rows.length;
      if (full) {
        while (end > 0 && _int(rows[end - 1]['ts']) == lastTs) {
          end--;
        }
        // A whole page of one timestamp: nothing can be held back without
        // stalling, so take it and step past that second.
        if (end == 0) end = rows.length;
      }
      for (var i = 0; i < end; i++) {
        await onRow(rows[i]);
      }
      if (!full) return;
      final next = end == rows.length ? lastTs : lastTs - 1;
      if (next > cursor) {
        cursor = next;
        continue;
      }
      // No progress. Reachable only if `ts` is a REAL column whose values
      // truncate onto the same second (a GRDB `Date` is stored that way), where
      // holding back the trailing second leaves the cursor exactly where it
      // was. Looping would hang the import outright, and re-reading the page
      // would append every RR beat in it a second time — so take the whole page
      // and step past that second.
      for (var i = end; i < rows.length; i++) {
        await onRow(rows[i]);
      }
      cursor = lastTs;
    }
  }

  /// Earliest and latest sample timestamp across every table we read, so the day
  /// walk covers days that carry (say) only a step counter.
  static Future<(int, int)?> _span(Database src, Set<String> tables) async {
    int? lo, hi;
    for (final t in const [
      'hrSample',
      'rrInterval',
      'gravitySample',
      'skinTempSample',
      'spo2Sample',
      'stepSample',
    ]) {
      if (!tables.contains(t)) continue;
      // The plausibility bound is applied INSIDE the aggregate, not to its
      // result. MIN/MAX collapse the table to two rows, so a single corrupt
      // timestamp — one `ts = 0`, one millisecond-scaled row — would otherwise
      // disqualify the entire table and, if every table has one, fail the
      // import as "no samples" on a backup holding years of data.
      final r = await src.rawQuery(
        'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM $t WHERE ts >= ? AND ts <= ?',
        [_kMinPlausibleTs, _kMaxPlausibleTs],
      );
      if (r.isEmpty) continue;
      final a = _int(r.first['lo']), b = _int(r.first['hi']);
      if (a == null || b == null) continue;
      lo = lo == null || a < lo ? a : lo;
      hi = hi == null || b > hi ? b : hi;
    }
    return (lo == null || hi == null) ? null : (lo, hi);
  }

  static Future<Set<String>> _columnNames(Database src, String table) async {
    final rows = await src.rawQuery('PRAGMA table_info($table)');
    return {for (final r in rows) (r['name'] as String?) ?? ''};
  }

  static Future<Set<String>> _tableNames(Database src) async {
    final rows = await src
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
    return {for (final r in rows) (r['name'] as String?) ?? ''};
  }

  static DateTime _localMidnight(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    return DateTime(d.year, d.month, d.day);
  }

  static int? _int(Object? v) => v is int
      ? v
      : v is num
          ? v.toInt()
          : null;

  static double? _num(Object? v) => v is num ? v.toDouble() : null;
}
