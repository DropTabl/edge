// "Delete everything" must not be repopulated by the band it is deleting.
//
// `resetAllData()` wipes the database but leaves the strap CONNECTED — its own
// documented order puts `signOut` (and the `unpair` inside it) LAST, because
// that flips the route and unwinds the UI. So the band keeps handing over
// historical records straight across the wipe, and one that lands after it is
// written into the fresh database and re-advertised as the data edge: the
// deleted installation, visible again on Home, with nothing left to explain it.
//
// `AppState._resetting` is the refusal flag that closes that window. It is
// private, and `resetAllData` needs the whole plugin stack (preferences,
// notifications, widget, telemetry, keychain) to run at all, so there is no
// behavioural test to write here. This greps instead — the same approach, and
// for the same reason, as `link_priority_structural_test.dart` and
// `no_debug_only_apis_test.dart`: the failure mode is a NEW ingest path added
// later that simply forgets the guard, which no test that runs the code can
// see.
//
// What is pinned:
//   1. every record-ingest callback AppState hands the engine checks
//      `_resetting` before it writes
//   2. `resetAllData` raises the flag, and lowers it in a `finally` (a
//      half-reset install that silently drops every record is worse than the
//      race it was closing)
//   3. `LocalDb.insertRecordsBatch` is not passed as a bare tear-off anywhere
//      in AppState — that is exactly how the drain path bypassed the guard

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/state/app_state.dart').readAsStringSync();

  test('both ingest callbacks refuse while a reset is in flight', () {
    // The singles path.
    final onRecord = RegExp(
      r'Future<void> _onRecord\([^)]*\) async \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(onRecord.hasMatch(src), isTrue,
        reason: '_onRecord must refuse before it writes');

    // The drain path, which is wired straight to LocalDb and so bypasses every
    // check AppState makes unless the closure carries one itself.
    final batch = RegExp(
      r'onRecordsBatch: \([^)]*\) async \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(batch.hasMatch(src), isTrue,
        reason: 'onRecordsBatch must refuse before it writes');
  });

  test('insertRecordsBatch is never handed over as a bare tear-off', () {
    // `onRecordsBatch: LocalDb.insertRecordsBatch` is the shape of the bug:
    // it hands the database straight to the engine with nothing in between.
    expect(
      src.contains('onRecordsBatch: LocalDb.insertRecordsBatch'),
      isFalse,
      reason: 'wrap it in a closure that checks _resetting',
    );
  });

  test('resetAllData raises the flag and always lowers it', () {
    final body = src.substring(src.indexOf('Future<void> resetAllData() async'));
    final raise = body.indexOf('_resetting = true;');
    final wipe = body.indexOf('LocalDb.wipeAll()');
    final lower = body.indexOf('_resetting = false;');
    final fin = body.indexOf('} finally {');

    expect(raise, greaterThanOrEqualTo(0), reason: 'the flag must be raised');
    expect(raise, lessThan(wipe),
        reason: 'raised BEFORE the wipe, or the window it closes is still open');
    expect(fin, greaterThanOrEqualTo(0), reason: 'lowering must be in a finally');
    expect(fin, lessThan(lower), reason: 'lowered inside that finally');
  });

  test('the data edge is cleared by the reset, not left in memory', () {
    final body = src.substring(src.indexOf('Future<void> resetAllData() async'));
    final end = body.indexOf('} finally {');
    final scope = body.substring(0, end);
    expect(scope.contains('_lastRecTs = null;'), isTrue);
    expect(scope.contains('lastSynced = null;'), isTrue);
  });
}
