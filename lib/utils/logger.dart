import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final log = Logger('ExampleLogger');

class LoggerInit {
  static final LoggerInit _instance = LoggerInit._internal();
  static LoggerInit get instance => _instance;

  LoggerInit._internal();

  File? _logFile;
  IOSink? _logSink;
  StreamSubscription<LogRecord>? _logSubscription;

  /// 日志文件最大大小: 2MB
  static const int _maxLogFileSize = 2 * 1024 * 1024;

  /// 保留的旧日志文件数量
  static const int _maxBackupFiles = 1;

  /// 时间戳格式
  static final DateFormat _timeFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  static String _formatTime(DateTime time) {
    return _timeFormat.format(time);
  }

  static initLogger() async {
    Logger.root.level = Level.INFO;
    instance._logSubscription = Logger.root.onRecord.listen((record) {
      if (!kReleaseMode) {
        developer.log(
            '${record.level.name}: ${_formatTime(record.time)}: ${record.message}');
      }
      LoggerInit.instance.log(record);
    });
  }

  Future<void> init() async {
    if (Config.enableDebug.value) {
      // 调试模式下开启详细日志
      Logger.root.level = Level.FINE;
      final appDir = await getApplicationSupportDirectory();
      final logPath = path.join(appDir.path, 'debug.log');
      _logFile = File(logPath);
      await _rotateIfNeeded();
      _logSink = _logFile?.openWrite(mode: FileMode.append);
    }
  }

  /// 检查日志文件大小，必要时进行轮换
  Future<void> _rotateIfNeeded() async {
    final file = _logFile;
    if (file == null || !file.existsSync()) return;

    final fileSize = await file.length();
    if (fileSize < _maxLogFileSize) return;

    // 关闭当前写入流
    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;

    final logDir = file.parent.path;
    final baseName = path.basenameWithoutExtension(file.path);
    final ext = path.extension(file.path);

    // 删除超出保留数量的旧日志
    for (var i = _maxBackupFiles; i >= 1; i--) {
      final older = File(path.join(logDir, '$baseName.$i$ext'));
      if (i == _maxBackupFiles && older.existsSync()) {
        await older.delete();
      } else if (older.existsSync() && i < _maxBackupFiles) {
        await older.rename(path.join(logDir, '$baseName.${i + 1}$ext'));
      }
    }

    // 将当前日志重命名为 .1 备份
    await file.rename(path.join(logDir, '$baseName.1$ext'));
  }

  void log(LogRecord record) {
    if (Config.enableDebug.value && _logSink != null) {
      _logSink?.writeln(
          '${record.level.name}: ${_formatTime(record.time)}: ${record.message}');
    }
  }

  String? get logFilePath => _logFile?.path;

  Future<void> dispose() async {
    await _logSubscription?.cancel();
    _logSubscription = null;
    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;
    _logFile = null;
  }
}
