// The BYOK key must survive a background relaunch on a locked phone.
//
// Two TestFlight reports: "I enter my AI API key, it works for a few minutes,
// then after the phone sleeps and wakes it's gone." The key was written with the
// plugin's default `whenUnlocked` accessibility, and this app is relaunched in
// the background constantly (BGProcessingTask, the BLE restore central) — often
// while the phone is locked, when that item cannot be read. `load()` cached the
// empty read as "no key", so the app asked the user to set one up again.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the keychain: records the options every write asks for, and
/// can be told to behave like a locked device.
class _FakeKeychain {
  final Map<String, String> items = {};
  final List<Map<Object?, Object?>> writeOptions = [];
  bool locked = false;
  bool throwOnRead = false;

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        if (throwOnRead) throw PlatformException(code: 'keychain');
        // A locked keychain does not error — it simply returns nothing, which
        // is indistinguishable from "no key" without the marker.
        if (locked) return null;
        return items[args['key'] as String];
      case 'write':
        items[args['key'] as String] = args['value'] as String;
        writeOptions.add((args['options'] as Map?) ?? const {});
        return null;
      case 'delete':
        items.remove(args['key'] as String);
        return null;
      case 'containsKey':
        return !locked && items.containsKey(args['key'] as String);
      case 'readAll':
        return locked ? <String, String>{} : items;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late _FakeKeychain keychain;

  setUp(() {
    keychain = _FakeKeychain();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, keychain.handle);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a key is stored so it survives a locked-device relaunch', () async {
    // The accessibility attribute is an Apple-keychain concept, and the plugin
    // picks its option set off defaultTargetPlatform (android under test).
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test', model: 'gpt-4o');

    expect(keychain.writeOptions, isNotEmpty);
    // `first_unlock`, not the plugin default of `unlocked`: readable from the
    // first unlock after boot, which is what a background relaunch needs.
    expect(
      keychain.writeOptions.last['accessibility'],
      'first_unlock',
      reason: 'a whenUnlocked item is unreadable during a locked relaunch',
    );
  });

  test('a locked keychain does not report the key as missing', () async {
    final saved = CoachConfig();
    await saved.save(apiKey: 'sk-test', model: 'gpt-4o');

    // A fresh process — the background relaunch — with the phone locked.
    keychain.locked = true;
    final relaunched = CoachConfig();
    await relaunched.load();

    expect(relaunched.hasKey, isFalse, reason: 'it genuinely could not read it');
    expect(relaunched.keyUnreadable, isTrue,
        reason: 'but it must not be reported as "no key configured"');

    // The user unlocks and opens the app.
    keychain.locked = false;
    await relaunched.refreshKeyIfUnreadable();
    expect(relaunched.apiKey, 'sk-test');
    expect(relaunched.keyUnreadable, isFalse);
  });

  test('a read that throws does not erase a key already in memory', () async {
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test', model: 'gpt-4o');
    expect(cfg.apiKey, 'sk-test');

    keychain.throwOnRead = true;
    await cfg.load();

    expect(cfg.apiKey, 'sk-test',
        reason: 'a failed read says nothing about what is stored');
    expect(cfg.keyUnreadable, isTrue);
  });

  test('no key configured still reads as no key, not as unreadable', () async {
    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.hasKey, isFalse);
    expect(cfg.keyUnreadable, isFalse,
        reason: 'nothing was ever saved — the setup prompt is correct here');
  });

  test('clearing the key clears the marker with it', () async {
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test');
    await cfg.save(apiKey: '');

    keychain.locked = true;
    final relaunched = CoachConfig();
    await relaunched.load();
    expect(relaunched.keyUnreadable, isFalse,
        reason: 'a deleted key must not leave the app claiming one exists');
  });

  test('a key written before the marker existed is upgraded once', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Legacy state: an item in the keychain, no marker in prefs.
    keychain.items['coach_api_key'] = 'sk-legacy';
    SharedPreferences.setMockInitialValues({});

    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.apiKey, 'sk-legacy');
    expect(keychain.writeOptions.length, 1,
        reason: 'rewritten once to carry the new accessibility');
    expect(keychain.writeOptions.single['accessibility'], 'first_unlock');

    // A second load must NOT write again — the Android Keystore is the
    // documented Samsung hang, and it has no business on every startup.
    await cfg.load();
    expect(keychain.writeOptions.length, 1);
  });
}
