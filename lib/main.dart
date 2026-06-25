import 'package:flutter/material.dart';

import 'screens/instances.dart';

void main() => runApp(const SnippetApp());

class SnippetApp extends StatelessWidget {
  const SnippetApp({super.key});

  @override
  Widget build(BuildContext context) {
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
      home: const InstancesScreen(),
    );
  }
}
