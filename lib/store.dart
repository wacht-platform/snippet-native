import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persists the list of saved daemon instances in shared_preferences.
class InstanceStore {
  static const _key = 'instances';

  Future<List<Instance>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw != null) {
      try {
        return (jsonDecode(raw) as List)
            .map((e) => Instance.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        return [];
      }
    }
    // Migrate a legacy single connection from the first app build.
    final url = p.getString('url');
    final token = p.getString('token');
    if (url != null && token != null) {
      final inst = Instance(name: hostOf(url), url: url, token: token);
      await save([inst]);
      await p.remove('url');
      await p.remove('token');
      return [inst];
    }
    return [];
  }

  Future<void> save(List<Instance> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }
}
