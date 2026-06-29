import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'platform.dart';
import 'store.dart';

const _fgChannel = 'snippet_fg';
const _alertChannel = 'snippet_alerts';
const _prefEnabled = 'notif_enabled';

/// Routed from a tapped notification (set by main with a navigator).
void Function(Map<String, dynamic> payload)? onNotifTap;

final FlutterLocalNotificationsPlugin _mainNotif = FlutterLocalNotificationsPlugin();

/// Build the device-wide events WebSocket URI for an instance.
Uri eventsUri(String baseUrl, String token) {
  final u = Uri.parse(baseUrl);
  return u.replace(
    scheme: u.scheme == 'https' ? 'wss' : 'ws',
    path: '/events',
    queryParameters: {'token': token},
  );
}

// ---------------------------------------------------------------------------
// Main-isolate setup: foreground-task config + tap routing + launch handling.
// ---------------------------------------------------------------------------
Future<void> initNotifications() async {
  if (!kMobile) return; // foreground task / local notifications are mobile-only
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: _fgChannel,
      channelName: 'Background watcher',
      channelDescription: 'Keeps watching your sessions for activity.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(15000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
      allowAutoRestart: true,
    ),
  );

  await _mainNotif.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: (resp) {
      final p = resp.payload;
      if (p != null) _route(p);
    },
  );
  // Cold start from a tapped notification.
  final launch = await _mainNotif.getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp == true) {
    final p = launch!.notificationResponse?.payload;
    if (p != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _route(p));
    }
  }
}

void _route(String payload) {
  try {
    onNotifTap?.call(jsonDecode(payload) as Map<String, dynamic>);
  } catch (_) {}
}

Future<bool> notificationsEnabled() async {
  if (!kMobile) return false;
  final sp = await SharedPreferences.getInstance();
  return sp.getBool(_prefEnabled) ?? false;
}

/// Enable/disable background watching. Returns an error string, or null on success.
Future<String?> setNotificationsEnabled(bool on) async {
  if (!kMobile) return 'Background watching is mobile-only.';
  final sp = await SharedPreferences.getInstance();
  await sp.setBool(_prefEnabled, on);
  if (!on) {
    await FlutterForegroundTask.stopService();
    return null;
  }
  return startWatching();
}

/// Start the foreground watcher (idempotent). Returns an error string or null.
Future<String?> startWatching() async {
  if (!kMobile) return 'Background watching is mobile-only.';
  var perm = await FlutterForegroundTask.checkNotificationPermission();
  if (perm != NotificationPermission.granted) {
    perm = await FlutterForegroundTask.requestNotificationPermission();
    if (perm != NotificationPermission.granted) {
      return 'Notification permission denied.';
    }
  }
  if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.restartService();
  } else {
    await FlutterForegroundTask.startService(
      serviceId: 4317,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'snippet',
      notificationText: 'Watching your sessions',
      callback: startNotificationCallback,
    );
  }
  return null;
}

/// Resume the watcher on app launch if the user had it enabled.
Future<void> resumeWatchingIfEnabled() async {
  if (!kMobile) return;
  if (await notificationsEnabled()) {
    await startWatching();
  }
}

// Tell the task whether the app is foreground and which session is open, so it
// can suppress a notification the user is already looking at.
void reportForeground(bool fg) {
  if (!kMobile) return;
  try {
    FlutterForegroundTask.sendDataToTask({'fg': fg});
  } catch (_) {}
}

void reportOpenSession(String? key) {
  if (!kMobile) return;
  try {
    FlutterForegroundTask.sendDataToTask({'open': key ?? ''});
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Task isolate: hold one /events WS per instance, raise local notifications.
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void startNotificationCallback() => FlutterForegroundTask.setTaskHandler(_NotifTaskHandler());

class _NotifTaskHandler extends TaskHandler {
  final _notif = FlutterLocalNotificationsPlugin();
  final Map<String, WebSocketChannel> _channels = {};
  List<Instance> _instances = const [];
  bool _fg = false;
  String _open = '';
  int _nid = 1000;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notif.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    _instances = await InstanceStore().load();
    _connectAll();
  }

  void _connectAll() {
    for (final inst in _instances) {
      if (_channels.containsKey(inst.url)) continue;
      try {
        final ch = WebSocketChannel.connect(eventsUri(inst.url, inst.token));
        _channels[inst.url] = ch;
        ch.stream.listen(
          (msg) => _onEvent(inst, msg),
          onDone: () => _channels.remove(inst.url),
          onError: (_) => _channels.remove(inst.url),
          cancelOnError: true,
        );
      } catch (_) {}
    }
  }

  void _onEvent(Instance inst, dynamic msg) {
    Map<String, dynamic> e;
    try {
      e = jsonDecode(msg as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final session = e['session']?.toString() ?? '';
    if (_fg && '${inst.url}|$session' == _open) return; // already on screen
    final title = e['title']?.toString() ?? 'session';
    final (String head, String body) = switch (e['kind']?.toString()) {
      'waiting' => ('${inst.label} needs your input', title),
      'done' => ('${inst.label} finished', title),
      'error' => ('${inst.label} hit an error', title),
      'idle' => ('${inst.label} stopped', title),
      _ => (inst.label, title),
    };
    _notif.show(
      id: _nid++,
      title: head,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _alertChannel,
          'Session activity',
          channelDescription: 'Activity on your connected machines',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode({
        'url': inst.url,
        'token': inst.token,
        'name': inst.label,
        'session': session,
        'title': title,
      }),
    );
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      final fg = data['fg'];
      final open = data['open'];
      if (fg is bool) _fg = fg;
      if (open is String) _open = open;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _connectAll(); // reconnect dropped

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final ch in _channels.values) {
      ch.sink.close();
    }
    _channels.clear();
  }
}
