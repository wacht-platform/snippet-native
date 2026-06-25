import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'screens/connect.dart';
import 'screens/sessions.dart';

void main() => runApp(const SnippetApp());

class SnippetApp extends StatefulWidget {
  const SnippetApp({super.key});

  @override
  State<SnippetApp> createState() => _SnippetAppState();
}

class _SnippetAppState extends State<SnippetApp> {
  DaemonClient? _client;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('url');
    final token = prefs.getString('token');
    if (!mounted) return;
    setState(() {
      if (url != null && token != null) _client = DaemonClient(url, token);
      _loading = false;
    });
  }

  Future<void> _connect(DaemonClient c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', c.baseUrl);
    await prefs.setString('token', c.token);
    if (!mounted) return;
    setState(() => _client = c);
  }

  Future<void> _disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('url');
    await prefs.remove('token');
    if (!mounted) return;
    setState(() => _client = null);
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_loading) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (_client == null) {
      home = ConnectScreen(onConnected: _connect);
    } else {
      home = SessionsScreen(client: _client!, onDisconnect: _disconnect);
    }
    return MaterialApp(
      title: 'snippet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C9CF5),
          brightness: Brightness.dark,
        ),
      ),
      home: home,
    );
  }
}
