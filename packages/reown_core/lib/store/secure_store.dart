import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:reown_core/store/i_store.dart';
import 'package:reown_core/utils/constants.dart';
import 'package:reown_core/utils/errors.dart';

class SecureStore implements IStore<Map<String, dynamic>> {
  static const String _logTag = '[reown_core][SecureStore]';

  late final FlutterSecureStorage _secureStorage;
  late final IStore<Map<String, dynamic>> _fallbackStorage;
  bool _initialized = false;
  bool _useFallbackStorage = false;

  final Map<String, Map<String, dynamic>> _map;

  @override
  Map<String, Map<String, dynamic>> get map => _map;

  @override
  List<String> get keys => map.keys.toList();

  @override
  List<Map<String, dynamic>> get values => map.values.toList();

  @override
  String get storagePrefix => ReownConstants.CORE_STORAGE_PREFIX;

  SecureStore({
    Map<String, Map<String, dynamic>>? defaultValue,
    required IStore<Map<String, dynamic>> fallbackStorage,
  }) : _map = defaultValue ?? {},
       _fallbackStorage = fallbackStorage;

  @override
  Future<void> init() async {
    debugPrint('$_logTag init: enter (already initialized=$_initialized)');
    if (_initialized) {
      debugPrint('$_logTag init: already initialized, returning');
      return;
    }

    try {
      // Try secure storage first.
      //
      // We scope the storage to a dedicated partition (iOS: `kSecAttrService`,
      // Android: a dedicated EncryptedSharedPreferences file) so that
      // `readAll()` only enumerates entries reown itself has written. Without
      // this isolation, on iOS `FlutterSecureStorage.readAll()` runs a
      // `SecItemCopyMatching` query under the default service and returns
      // every keychain item stored by the host app or any other library using
      // the default options. If any of those values are stored as `NSData`,
      // the Swift bridging layer force-casts to `NSString` and the process is
      // terminated with an uncatchable fatalError before Dart can handle it.
      debugPrint('$_logTag init: constructing FlutterSecureStorage');
      _secureStorage = const FlutterSecureStorage(
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          sharedPreferencesName: ReownConstants.SECURE_STORAGE_ANDROID_PREFS_NAME,
          preferencesKeyPrefix: ReownConstants.SECURE_STORAGE_ANDROID_PREFS_KEY_PREFIX,
        ),
        iOptions: IOSOptions(
          accountName: ReownConstants.SECURE_STORAGE_IOS_ACCOUNT_NAME,
          accessibility: KeychainAccessibility.first_unlock,
        ),
      );
      debugPrint('$_logTag init: FlutterSecureStorage constructed');

      debugPrint('$_logTag init: calling restore()');
      await restore();
      debugPrint('$_logTag init: restore() completed');
    } catch (e, stackTrace) {
      // Fall back to regular storage if secure storage fails.
      debugPrint(
        '$_logTag init: secure storage path failed, falling back to '
        'shared_prefs store. error=$e\n$stackTrace',
      );
      _useFallbackStorage = true;
      // Try to restore from fallback storage
      debugPrint('$_logTag init: calling _restoreFromFallback()');
      await _restoreFromFallback();
      debugPrint('$_logTag init: _restoreFromFallback() completed');
    }

    _initialized = true;
    debugPrint(
      '$_logTag init: completed (useFallback=$_useFallbackStorage, '
      'cachedKeyCount=${_map.length})',
    );
  }

  @override
  Map<String, dynamic>? get(String key) {
    debugPrint('$_logTag get: key=$key');
    _checkInitialized();

    final String keyWithPrefix = _addPrefix(key);
    if (_map.containsKey(keyWithPrefix)) {
      debugPrint('$_logTag get: cache hit for $keyWithPrefix');
      return _map[keyWithPrefix];
    }

    // For secure storage, we can't easily read all keys at once
    // So we'll return null if not in memory, similar to SharedPrefsStores behavior
    debugPrint('$_logTag get: cache miss for $keyWithPrefix, returning null');
    return null;
  }

  @override
  bool has(String key) {
    debugPrint('$_logTag has: key=$key');
    _checkInitialized();
    final String keyWithPrefix = _addPrefix(key);

    // Only check memory for secure storage (can't check secure storage synchronously)
    final bool result = _map.containsKey(keyWithPrefix);
    debugPrint('$_logTag has: $keyWithPrefix => $result');
    return result;
  }

  @override
  List<Map<String, dynamic>> getAll() {
    debugPrint('$_logTag getAll: returning ${_map.length} cached entries');
    _checkInitialized();
    return values;
  }

  @override
  Future<void> set(String key, Map<String, dynamic> value) async {
    debugPrint('$_logTag set: key=$key');
    _checkInitialized();

    final String keyWithPrefix = _addPrefix(key);
    _map[keyWithPrefix] = value;

    if (_useFallbackStorage) {
      debugPrint('$_logTag set: writing $keyWithPrefix to fallback storage');
      await _fallbackStorage.set(key, value);
      debugPrint('$_logTag set: fallback write completed for $keyWithPrefix');
    } else {
      try {
        final stringValue = jsonEncode(value);
        debugPrint('$_logTag set: writing $keyWithPrefix to secure storage');
        await _secureStorage.write(key: keyWithPrefix, value: stringValue);
        debugPrint('$_logTag set: secure write completed for $keyWithPrefix');
      } catch (e) {
        debugPrint('$_logTag set: secure write FAILED for $keyWithPrefix, error=$e');
        throw Errors.getInternalError(
          Errors.MISSING_OR_INVALID,
          context: e.toString(),
        );
      }
    }
  }

  @override
  Future<void> update(String key, Map<String, dynamic> value) async {
    debugPrint('$_logTag update: key=$key');
    _checkInitialized();

    final String keyWithPrefix = _addPrefix(key);
    if (!map.containsKey(keyWithPrefix)) {
      debugPrint('$_logTag update: no matching key for $keyWithPrefix');
      throw Errors.getInternalError(Errors.NO_MATCHING_KEY);
    } else {
      _map[keyWithPrefix] = value;
      if (_useFallbackStorage) {
        debugPrint('$_logTag update: writing $keyWithPrefix to fallback storage');
        await _fallbackStorage.update(key, value);
        debugPrint('$_logTag update: fallback write completed for $keyWithPrefix');
      } else {
        try {
          final stringValue = jsonEncode(value);
          debugPrint('$_logTag update: writing $keyWithPrefix to secure storage');
          await _secureStorage.write(key: keyWithPrefix, value: stringValue);
          debugPrint('$_logTag update: secure write completed for $keyWithPrefix');
        } catch (e) {
          debugPrint('$_logTag update: secure write FAILED for $keyWithPrefix, error=$e');
          throw Errors.getInternalError(
            Errors.MISSING_OR_INVALID,
            context: e.toString(),
          );
        }
      }
    }
  }

  @override
  Future<void> delete(String key) async {
    debugPrint('$_logTag delete: key=$key');
    _checkInitialized();

    final String keyWithPrefix = _addPrefix(key);
    _map.remove(keyWithPrefix);

    if (_useFallbackStorage) {
      debugPrint('$_logTag delete: deleting $keyWithPrefix from fallback storage');
      await _fallbackStorage.delete(key);
      debugPrint('$_logTag delete: fallback delete completed for $keyWithPrefix');
    } else {
      debugPrint('$_logTag delete: deleting $keyWithPrefix from secure storage');
      await _secureStorage.delete(key: keyWithPrefix);
      debugPrint('$_logTag delete: secure delete completed for $keyWithPrefix');
    }
  }

  @override
  Future<void> deleteAll() async {
    debugPrint('$_logTag deleteAll: enter (useFallback=$_useFallbackStorage)');
    _checkInitialized();

    if (_useFallbackStorage) {
      debugPrint('$_logTag deleteAll: clearing fallback storage');
      await _fallbackStorage.deleteAll();
      debugPrint('$_logTag deleteAll: fallback storage cleared');
    } else {
      // Get all keys from secure storage and delete them
      debugPrint('$_logTag deleteAll: calling _secureStorage.readAll()');
      final allKeys = await _secureStorage.readAll();
      debugPrint('$_logTag deleteAll: readAll returned ${allKeys.length} entries');
      for (final key in allKeys.keys) {
        if (key.startsWith(storagePrefix)) {
          debugPrint('$_logTag deleteAll: deleting $key');
          await _secureStorage.delete(key: key);
        }
      }
      debugPrint('$_logTag deleteAll: secure storage cleared');
    }

    _map.clear();
    debugPrint('$_logTag deleteAll: in-memory map cleared');
  }

  Future<void> restore() async {
    debugPrint('$_logTag restore: enter (useFallback=$_useFallbackStorage)');
    if (_useFallbackStorage) {
      debugPrint('$_logTag restore: skipped — fallback in use');
      return;
    }

    try {
      // Get all keys from secure storage.
      //
      // NOTE: this is the call that historically crashed the process on iOS
      // when the keychain contained `NSData` entries written by other libs.
      // With the scoped `accountName` configured in `init()`, `readAll()`
      // only enumerates reown's own partition, so the cast crash should not
      // be reachable any more — but we still log around it so any future
      // regression is immediately attributable.
      debugPrint('$_logTag restore: calling _secureStorage.readAll()');
      final allKeys = await _secureStorage.readAll();
      debugPrint('$_logTag restore: readAll returned ${allKeys.length} entries');

      // Restore data to memory map
      int restored = 0;
      int skippedPrefix = 0;
      int skippedDecode = 0;
      for (final entry in allKeys.entries) {
        final key = entry.key;
        final value = entry.value;

        if (key.startsWith(storagePrefix)) {
          try {
            final decodedValue = jsonDecode(value);
            _map[key] = decodedValue;
            restored++;
          } catch (e) {
            // Skip corrupted data
            skippedDecode++;
            debugPrint(
              '$_logTag restore: failed to decode value for key $key: $e',
            );
          }
        } else {
          skippedPrefix++;
        }
      }
      debugPrint(
        '$_logTag restore: done. restored=$restored, '
        'skippedPrefix=$skippedPrefix, skippedDecode=$skippedDecode',
      );
    } catch (e, stackTrace) {
      debugPrint('$_logTag restore: FAILED. error=$e\n$stackTrace');
      rethrow;
    }
  }

  Future<void> _restoreFromFallback() async {
    debugPrint('$_logTag _restoreFromFallback: enter');
    try {
      // Get all keys from fallback storage
      debugPrint('$_logTag _restoreFromFallback: calling _fallbackStorage.getAll()');
      final allKeys = _fallbackStorage.getAll();
      debugPrint(
        '$_logTag _restoreFromFallback: getAll returned ${allKeys.length} entries',
      );

      // Restore data to memory map
      int restored = 0;
      for (final entry in allKeys) {
        final key = entry.keys.first;
        final value = entry.values.first;

        if (key.startsWith(storagePrefix)) {
          _map[key] = value;
          restored++;
        }
      }
      debugPrint('$_logTag _restoreFromFallback: done. restored=$restored');
    } catch (e, stackTrace) {
      debugPrint(
        '$_logTag _restoreFromFallback: FAILED. error=$e\n$stackTrace',
      );
    }
  }

  String _addPrefix(String key) {
    return '$storagePrefix$key';
  }

  void _checkInitialized() {
    if (!_initialized) {
      debugPrint('$_logTag _checkInitialized: NOT initialized — throwing');
      throw Errors.getInternalError(Errors.NOT_INITIALIZED);
    }
  }
}
