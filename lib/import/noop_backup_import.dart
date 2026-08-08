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

/// Every table read, and the columns wanted from it. ONE definition: the probe
/// and the reads both key off this, so a name can no longer be spelled one way
/// here and another at a call site. That typo was silent — a mistyped table
/// simply produced an empty column list, the read skipped it, and every gravity
/// or skin-temperature sample vanished from the import with no error and a
/// still-positive day count.
const Map<String, List<String>> _kTableCols = {
  'hrSample': ['ts', 'bpm'],
  'rrInterval': ['ts', 'rrMs'],
  'gravitySample': ['ts', 'x', 'y', 'z'],
  'skinTempSample': ['ts', 'raw'],
  'spo2Sample': ['ts', 'red', 'ir'],
  'stepSample': ['ts', 'counter'],
};

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

    // Probe every table's columns ONCE. The schema cannot change during a
    // read-only import, and doing it inside the day walk cost a
    // `PRAGMA table_info` per table per day — thousands of pointless queries on
    // a long backup. A table whose columns have drifted resolves to a short
    // list here and is skipped by `_read`, rather than failing mid-import with
    // a raw `no such column` after days have already been written.
    final columns = <String, List<String>>{};
    for (final e in _kTableCols.entries) {
      if (!tables.contains(e.key)) continue;
      final have = await _columnNames(src, e.key);
      columns[e.key] = [for (final c in e.value) if (have.contains(c)) c];
    }

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
      await _read(src, tables, columns, 'hrSample', from, to, (r) async {
        final ts = _int(r['ts']), v = _int(r['bpm']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.hr(ts, v);
      });
      await _read(src, tables, columns, 'rrInterval', from, to,
          (r) async {
        final ts = _int(r['ts']), v = _num(r['rrMs']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.rr(ts, v);
      });
      await _read(src, tables, columns, 'gravitySample', from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.gravity(ts, _num(r['x']), _num(r['y']), _num(r['z']));
        }
      });
      await _read(src, tables, columns, 'skinTempSample', from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) ingest.skinTemp(ts, _int(r['raw']));
      });
      await _read(src, tables, columns, 'spo2Sample', from, to,
          (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.spo2(ts, _int(r['red']), _int(r['ir']));
        }
      });
      await _read(src, tables, columns, 'stepSample', from, to,
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
  /// A table the backup does not have — or one whose columns have drifted — is
  /// skipped rather than failing the import mid-way.
  ///
  /// Paged by KEYSET (`ts > last`), not OFFSET: LIMIT/OFFSET re-walks and
  /// re-discards every skipped row, so paging an 86,400-row day turns quadratic.
  ///
  /// The cursor is the RAW column value, never a truncated second. `ts` is not
  /// unique — `rrInterval`'s key is (deviceId, ts, rrMs), so one second holds
  /// several beats — so a page boundary can land inside a timestamp, and the
  /// trailing rows sharing it are held back and re-read whole on the next page.
  /// Keying that cursor on `ts` truncated to an int looks equivalent and is not:
  /// against a REAL column (a GRDB `Date` is stored as one) `ts > 3.0` does not
  /// exclude `3.2`, so the same rows come back forever — or, with a guard
  /// against that, the read stops early and silently drops the rest of the day.
  static Future<void> _read(
    Database src,
    Set<String> tables,
    Map<String, List<String>> columns,
    String table,
    int from,
    int to,
    Future<void> Function(Map<String, Object?> row) onRow,
  ) async {
    // A table name with no entry is a programming error, not a schema
    // variation — fail loudly here rather than silently importing without that
    // channel.
    final cols = _kTableCols[table]!;
    if (!tables.contains(table)) return;
    final usable = columns[table] ?? const <String>[];
    if (usable.length < cols.length) return;

    // `ts >= from` on the FIRST page, `ts > cursor` after. Not `ts > from - 1`:
    // that is only equivalent for integral timestamps, and against a fractional
    // one it makes the open interval (to-1, to) belong to BOTH the day that
    // ends at `to` and the day that starts there. The straddling rows are then
    // read twice, and while the map-keyed channels absorb that, `rr()` APPENDS —
    // a duplicated beat corrupts the night's RMSSD rather than costing a row.
    num cursor = from;
    var firstPage = true;
    while (true) {
      final rows = await src.query(
        table,
        columns: cols,
        where: firstPage ? 'ts >= ? AND ts < ?' : 'ts > ? AND ts < ?',
        whereArgs: [cursor, to],
        orderBy: 'ts',
        limit: kNoopBackupPageRows,
      );
      firstPage = false;
      if (rows.isEmpty) return;
      final full = rows.length == kNoopBackupPageRows;

      // Hold back the trailing rows that share the last timestamp EXACTLY; the
      // next page re-reads that timestamp whole.
      var end = rows.length;
      if (full) {
        final lastTs = _raw(rows.last['ts']);
        while (end > 0 && _raw(rows[end - 1]['ts']) == lastTs) {
          end--;
        }
      }
      // A whole page sharing one timestamp cannot hold anything back without
      // stalling. Take it, then drain whatever else carries that exact value
      // before stepping past it — stepping past directly would silently lose
      // the remainder, which is the partial-history failure this file refuses
      // everywhere else. Offset-paged, but bounded to one timestamp's rows.
      if (end == 0) {
        final lastTs = _raw(rows.last['ts']);
        for (final r in rows) {
          await onRow(r);
        }
        var drained = rows.length;
        while (lastTs != null) {
          final more = await src.query(
            table,
            columns: cols,
            where: 'ts = ?',
            whereArgs: [lastTs],
            orderBy: 'ts',
            limit: kNoopBackupPageRows,
            offset: drained,
          );
          if (more.isEmpty) break;
          for (final r in more) {
            await onRow(r);
          }
          drained += more.length;
          if (more.length < kNoopBackupPageRows) break;
        }
        if (lastTs == null) return; // a NULL ts cannot be paged past
        cursor = lastTs;
        continue;
      }

      for (var i = 0; i < end; i++) {
        await onRow(rows[i]);
      }
      if (!full) return;
      // The cursor is the last row actually EMITTED, so nothing is skipped and
      // the next page starts strictly after it.
      final next = _raw(rows[end - 1]['ts']);
      if (next == null || next <= cursor) return; // non-numeric ts: stop
      cursor = next;
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

  /// The timestamp column's value as stored — INTEGER in every NOOP schema seen
  /// so far, but REAL is representable and must page correctly either way.
  static num? _raw(Object? v) => v is num ? v : null;
}
