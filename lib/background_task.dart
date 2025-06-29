import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class TripLoggerTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('[TripLoggerTaskHandler] Service started at $timestamp');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isUnexpected) async {
    print('[TripLoggerTaskHandler] Service destroyed at $timestamp. Unexpected: $isUnexpected');
  }

  @override
  void onEvent(DateTime timestamp) {
    print('[TripLoggerTaskHandler] onEvent: $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    print('[TripLoggerTaskHandler] onRepeatEvent: $timestamp');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onButtonPressed(String id) {
    print('[TripLoggerTaskHandler] Button pressed: $id');
  }
}
