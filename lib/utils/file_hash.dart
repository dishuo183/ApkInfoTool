import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:crypto/crypto.dart';

/// 简单的 Digest 收集器，用于 chunked conversion
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 在独立 isolate 中使用流式计算文件的 MD5 和 SHA1 哈希值
/// 内存占用恒定 O(chunkSize)，不随文件大小增长
(String, String) _computeHashesInIsolate(String filePath) {
  final file = File(filePath);
  final input = file.openSync();

  const chunkSize = 4 * 1024 * 1024; // 4MB
  final buffer = Uint8List(chunkSize);

  final md5Output = _DigestSink();
  final sha1Output = _DigestSink();
  final md5Chunked = md5.startChunkedConversion(md5Output);
  final sha1Chunked = sha1.startChunkedConversion(sha1Output);

  try {
    int bytesRead;
    while ((bytesRead = input.readIntoSync(buffer)) > 0) {
      final chunk = Uint8List.sublistView(buffer, 0, bytesRead);
      md5Chunked.add(chunk);
      sha1Chunked.add(chunk);
    }
  } finally {
    input.closeSync();
  }

  md5Chunked.close();
  sha1Chunked.close();

  return (md5Output.value.toString(), sha1Output.value.toString());
}

/// 在独立 isolate 中使用流式计算文件的 MD5 哈希值
String _computeMd5InIsolate(String filePath) {
  final file = File(filePath);
  final input = file.openSync();

  const chunkSize = 4 * 1024 * 1024;
  final buffer = Uint8List(chunkSize);

  final output = _DigestSink();
  final chunked = md5.startChunkedConversion(output);

  try {
    int bytesRead;
    while ((bytesRead = input.readIntoSync(buffer)) > 0) {
      chunked.add(Uint8List.sublistView(buffer, 0, bytesRead));
    }
  } finally {
    input.closeSync();
  }

  chunked.close();
  return output.value.toString();
}

/// 在独立 isolate 中使用流式计算文件的 SHA1 哈希值
String _computeSha1InIsolate(String filePath) {
  final file = File(filePath);
  final input = file.openSync();

  const chunkSize = 4 * 1024 * 1024;
  final buffer = Uint8List(chunkSize);

  final output = _DigestSink();
  final chunked = sha1.startChunkedConversion(output);

  try {
    int bytesRead;
    while ((bytesRead = input.readIntoSync(buffer)) > 0) {
      chunked.add(Uint8List.sublistView(buffer, 0, bytesRead));
    }
  } finally {
    input.closeSync();
  }

  chunked.close();
  return output.value.toString();
}

/// 计算文件的 MD5 哈希值（在独立 isolate 中执行）
Future<String> computeMd5(String filePath) async {
  try {
    return await Isolate.run(() => _computeMd5InIsolate(filePath));
  } catch (e) {
    log.warning('computeMd5: failed to compute MD5: $e');
    rethrow;
  }
}

/// 计算文件的 SHA1 哈希值（在独立 isolate 中执行）
Future<String> computeSha1(String filePath) async {
  try {
    return await Isolate.run(() => _computeSha1InIsolate(filePath));
  } catch (e) {
    log.warning('computeSha1: failed to compute SHA1: $e');
    rethrow;
  }
}

/// 同时计算文件的 MD5 和 SHA1 哈希值（在独立 isolate 中执行）
/// 返回 (md5, sha1) 元组
/// 只读取一次文件，同时计算两个哈希值，效率更高
Future<(String, String)> computeFileHashes(String filePath) async {
  try {
    return await Isolate.run(() => _computeHashesInIsolate(filePath));
  } catch (e) {
    log.warning('computeFileHashes: failed to compute hashes: $e');
    rethrow;
  }
}
