import 'package:flutter/material.dart';

import 'screens/instances.dart';
import 'theme.dart';

void main() => runApp(const SnippetApp());

class SnippetApp extends StatelessWidget {
  const SnippetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'snippet',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const InstancesScreen(),
    );
  }
}
