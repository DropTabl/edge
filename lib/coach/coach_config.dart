// CoachConfig — local, BYOK settings for the AI coach. The API key is stored in
// the platform keychain/keystore (flutter_secure_storage); base URL + model in
// SharedPreferences. NOTHING here ever touches our backend — the key stays on the
// device and the app calls the OpenAI-compatible provider directly.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CoachConfig extends ChangeNotifier {
  static const _kBaseUrl = 'coach_base_url';
  static const _kModel = 'coach_model';
  static const _kKey = 'coach_api_key'; // secure storage

  /// Set whenever a key is written, cleared when it is deleted. The keychain
  /// itself cannot answer "is there a key I currently can't read?" — a locked
  /// device and an empty keychain both read as nothing — so the answer is kept
  /// here, where it is always readable.
  static const _kKeyPresent = 'coach_api_key_present';

  static const String defaultBaseUrl = 'https://api.openai.com/v1';

  /// FIRST-UNLOCK, not the plugin's default WHEN-UNLOCKED.
  ///
  /// This app is relaunched in the background constantly — BGProcessingTask, the
  /// BLE restore central waking on a link drop — and those relaunches routinely
  /// happen while the phone is LOCKED, i.e. exactly when a `whenUnlocked` item
  /// cannot be read. That read then returned nothing, `load()` cached the
  /// nothing as "no key", and by the time the user opened the app their key had
  /// silently vanished ("works for a few minutes, then it's gone after
  /// sleep/wake" — two TestFlight reports). `first_unlock` keeps the item
  /// readable from the first unlock after boot onwards, which is what a
  /// background-heavy app needs. The key still never leaves the device.
  static const _apple = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );
  static const _macos = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  String _baseUrl = defaultBaseUrl;
  String _model = '';
  String? _key; // cached in-memory after load

  /// True when a key IS stored but this process could not read it (a locked
  /// keychain, a wedged keystore). Distinct from "no key configured", which the
  /// user can fix by pasting one — this one fixes itself on the next unlocked
  /// read, and telling them to set a key up again would be wrong.
  bool _keyUnreadable = false;
  bool get keyUnreadable => _keyUnreadable;

  String get baseUrl => _baseUrl;
  String get model => _model;
  String? get apiKey => _key;
  bool get hasKey => _key != null && _key!.isNotEmpty;
  bool get configured => hasKey && _baseUrl.isNotEmpty && _model.isNotEmpty;

  /// Normalised base, no trailing slash.
  String get apiBase {
    var b = _baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
    _model = prefs.getString(_kModel) ?? '';
    final expectKey = prefs.getBool(_kKeyPresent) ?? false;
    try {
      final read = await _secure.read(
        key: _kKey,
        iOptions: _apple,
        mOptions: _macos,
      );
      if (read != null && read.isNotEmpty) {
        _key = read;
        _keyUnreadable = false;
        // Upgrade an item written before this class asked for `first_unlock`:
        // accessibility is set at WRITE time, so an existing key keeps the old
        // attribute until it is written again. Keyed on the marker's absence so
        // this happens exactly once — a write on every load would put the
        // Android Keystore (the documented Samsung Knox hang) on the startup
        // path for no reason.
        if (!expectKey) {
          await _secure.write(
            key: _kKey,
            value: read,
            iOptions: _apple,
            mOptions: _macos,
          );
          await prefs.setBool(_kKeyPresent, true);
        }
      } else if (expectKey) {
        // We know one was saved, so an empty read is the keychain being
        // unavailable — NOT the user having no key. Keep whatever is cached
        // (usually nothing on a fresh process) and say why.
        _keyUnreadable = true;
      } else {
        _key = null;
        _keyUnreadable = false;
      }
    } catch (_) {
      // A read that THREW tells us nothing about the stored key, so it must not
      // overwrite one we already hold in memory.
      _keyUnreadable = expectKey;
    }
    notifyListeners();
  }

  /// Re-read the key if it is known to exist but could not be read. Cheap no-op
  /// otherwise — safe to call on every resume, which is when a phone that was
  /// locked during a background relaunch becomes readable again.
  Future<void> refreshKeyIfUnreadable() async {
    if (!_keyUnreadable) return;
    await load();
  }

  Future<void> save({String? baseUrl, String? model, String? apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      _baseUrl = baseUrl.trim().isEmpty ? defaultBaseUrl : baseUrl.trim();
      await prefs.setString(_kBaseUrl, _baseUrl);
    }
    if (model != null) {
      _model = model.trim();
      await prefs.setString(_kModel, _model);
    }
    if (apiKey != null) {
      final k = apiKey.trim();
      _key = k.isEmpty ? null : k;
      _keyUnreadable = false;
      if (k.isEmpty) {
        await _secure.delete(key: _kKey, iOptions: _apple, mOptions: _macos);
        await prefs.setBool(_kKeyPresent, false);
      } else {
        await _secure.write(
          key: _kKey,
          value: k,
          iOptions: _apple,
          mOptions: _macos,
        );
        // Written AFTER the keychain succeeds: a marker claiming a key that was
        // never stored would leave the app permanently reporting "unreadable".
        await prefs.setBool(_kKeyPresent, true);
      }
    }
    notifyListeners();
  }
}
