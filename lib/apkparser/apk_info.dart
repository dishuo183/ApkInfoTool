import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:apk_info_tool/apkparser/adaptive_icon_renderer.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:path/path.dart' as path;
import 'xapk_info.dart';

bool _isArchiveApk(String apkPath) {
  final extension = path.extension(apkPath).toLowerCase();
  return extension == '.xapk' || extension == '.apkm' || extension == '.apks';
}

String _archiveTypeFromExtension(String extension) {
  if (extension == '.apkm') return 'APKM';
  if (extension == '.apks') return 'APKS';
  return 'XAPK';
}

final _kSplitAbiTokens = <String>{
  'armeabi',
  'armeabi_v7a',
  'arm64_v8a',
  'x86',
  'x86_64',
  'mips',
  'mips64',
};

final _kSplitDensityTokens = <String>{
  'ldpi',
  'mdpi',
  'hdpi',
  'xhdpi',
  'xxhdpi',
  'xxxhdpi',
  'tvdpi',
};

bool _looksLikeSplitAbi(String value) {
  if (_kSplitAbiTokens.contains(value)) return true;
  return value.contains('v7a') ||
      value.contains('v8a') ||
      value.contains('x86');
}

bool _looksLikeSplitDensity(String value) {
  if (_kSplitDensityTokens.contains(value)) return true;
  return value.endsWith('dpi');
}

bool _looksLikeSplitLanguage(String value) {
  return RegExp(r'^[a-z]{2,3}(-r[a-z]{2})?$').hasMatch(value);
}

bool _hasOnlyPlaceholderLocales(List<String> locales) {
  if (locales.isEmpty) return false;
  final normalized = locales.map((e) => e.trim().toLowerCase()).toList();
  return normalized.every((e) => e == '--_--' || e == '--');
}

void _inferLocalesAndAbisFromSplits(
  ApkInfo apkInfo,
  List<String> splitApks,
) {
  final needLocales =
      apkInfo.locales.isEmpty || _hasOnlyPlaceholderLocales(apkInfo.locales);
  final needAbis = apkInfo.nativeCodes.isEmpty;
  if (!needLocales && !needAbis) return;

  final locales = <String>[];
  final localesSeen = <String>{};
  final abis = <String>[];
  final abisSeen = <String>{};

  for (final entry in splitApks) {
    final baseName = path.basenameWithoutExtension(entry).toLowerCase();
    String? suffix;
    if (baseName.startsWith('split_config.')) {
      suffix = baseName.substring('split_config.'.length);
    } else if (baseName.startsWith('config.')) {
      suffix = baseName.substring('config.'.length);
    } else {
      continue;
    }

    if (suffix.isEmpty) continue;
    if (needAbis && _looksLikeSplitAbi(suffix)) {
      if (abisSeen.add(suffix)) abis.add(suffix);
      continue;
    }
    if (_looksLikeSplitDensity(suffix)) continue;
    if (needLocales && _looksLikeSplitLanguage(suffix)) {
      if (localesSeen.add(suffix)) locales.add(suffix);
    }
  }

  if (needLocales && locales.isNotEmpty) {
    apkInfo.locales = locales;
  }
  if (needAbis && abis.isNotEmpty) {
    apkInfo.nativeCodes = abis;
  }
}

String? _findBaseApkEntry(List<String> apkEntries) {
  if (apkEntries.isEmpty) return null;
  for (final entry in apkEntries) {
    final name = path.basename(entry).toLowerCase();
    if (name == 'base.apk' || name.endsWith('/base.apk')) {
      return entry;
    }
  }
  for (final entry in apkEntries) {
    final name = path.basename(entry).toLowerCase();
    if (!name.contains('config.')) {
      return entry;
    }
  }
  return apkEntries.first;
}

Future<ApkInfo?> getApkInfo(String apk) async {
  log.info("getApkInfo: apk=[$apk] start");
  final apkInfo = ApkInfo();
  apkInfo.apkPath = apk;
  apkInfo.apkSize = File(apk).lengthSync();

  // 检查是否为XAPK/APKM/APKS格式
  if (_isArchiveApk(apk)) {
    final extension = path.extension(apk).toLowerCase();
    log.info("getApkInfo: parsing XAPK/APKM/APKS file");
    apkInfo.isXapk = true;
    apkInfo.archiveType = _archiveTypeFromExtension(extension);

    final manifest = await parseXapkManifest(apk);
    final zip = ZipHelper();
    Directory? tempDir;
    String? baseApkPath;
    try {
      if (zip.open(apk)) {
        apkInfo.archiveApks = zip.listFiles(extension: '.apk');
        apkInfo.obbFiles = zip.listFiles(extension: '.obb');

        final baseEntry = _findBaseApkEntry(apkInfo.archiveApks);
        if (baseEntry != null) {
          tempDir = await Directory.systemTemp.createTemp('apk_info_base');
          baseApkPath = path.join(tempDir.path, path.basename(baseEntry));
          final extracted = await zip.extractFile(baseEntry, baseApkPath);
          if (extracted) {
            try {
              final aaptPath = CommandTools.findAapt2Path();
              if (aaptPath == null || aaptPath.isEmpty) {
                throw Exception(t.parse.please_set_path(name: 'aapt2'));
              }
              final result = await Process.run(
                aaptPath,
                ['dump', 'badging', baseApkPath],
                stdoutEncoding: utf8,
                stderrEncoding: utf8,
              ).timeout(
                const Duration(seconds: 120),
                onTimeout: () {
                  throw TimeoutException('Parse timeout');
                },
              );
              if (result.exitCode == 0) {
                final originalPath = apkInfo.apkPath;
                apkInfo.apkPath = baseApkPath;
                parseApkInfoFromOutput(result.stdout.toString(), apkInfo);
                final iconImage = await apkInfo.loadIcon();
                if (iconImage != null) {
                  apkInfo.mainIconImage ??= iconImage;
                }
                apkInfo.apkPath = originalPath;
              }
            } catch (e) {
              log.info("getApkInfo: base APK parse failed: $e");
            }
          }
        }
      }
    } finally {
      zip.close();
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }

    if (manifest != null) {
      if (manifest.packageName?.isNotEmpty == true) {
        apkInfo.packageName = manifest.packageName;
      }
      if (manifest.versionCode != null && manifest.versionCode! > 0) {
        apkInfo.versionCode = manifest.versionCode;
      }
      if (manifest.versionName?.isNotEmpty == true) {
        apkInfo.versionName = manifest.versionName;
      }
      if (manifest.minSdkVersion != null && manifest.minSdkVersion! > 0) {
        apkInfo.sdkVersion = manifest.minSdkVersion;
      }
      if (manifest.targetSdkVersion != null && manifest.targetSdkVersion! > 0) {
        apkInfo.targetSdkVersion = manifest.targetSdkVersion;
      }
      if (manifest.name?.isNotEmpty == true) {
        apkInfo.label = manifest.name;
        apkInfo.xapkName = manifest.name;
      }
      if (apkInfo.usesPermissions.isEmpty && manifest.permissions.isNotEmpty) {
        apkInfo.usesPermissions = manifest.permissions;
      }
      if (manifest.splitConfigs.isNotEmpty) {
        apkInfo.splitConfigs = manifest.splitConfigs;
      }
      if (manifest.splitApks.isNotEmpty) {
        apkInfo.splitApks = manifest.splitApks.map((e) => e.file).toList();
      }
      if (manifest.totalSize != null && manifest.totalSize! > 0) {
        apkInfo.totalSize = manifest.totalSize;
      }
      final iconImage = await loadXapkIcon(apk, iconPath: manifest.icon);
      if (iconImage != null && apkInfo.mainIconImage == null) {
        apkInfo.mainIconImage = iconImage;
      }
    } else {
      final iconImage = await loadXapkIcon(apk);
      if (iconImage != null && apkInfo.mainIconImage == null) {
        apkInfo.mainIconImage = iconImage;
      }
    }

    if (apkInfo.splitApks.isEmpty) {
      apkInfo.splitApks = apkInfo.archiveApks;
    }
    _inferLocalesAndAbisFromSplits(apkInfo, apkInfo.splitApks);
    apkInfo.totalSize ??= apkInfo.apkSize;

    if (apkInfo.packageName == null &&
        apkInfo.versionName == null &&
        apkInfo.label == null &&
        apkInfo.archiveApks.isEmpty &&
        manifest == null) {
      log.info("getApkInfo: failed to parse XAPK/APKM/APKS");
      return null;
    }

    return apkInfo;
  }

  // 原有的APK解析逻辑
  final aaptPath = CommandTools.findAapt2Path();
  if (aaptPath == null || aaptPath.isEmpty) {
    throw Exception(t.parse.please_set_path(name: 'aapt2'));
  }
  final start = DateTime.now();

  try {
    var result = await Process.run(
      aaptPath,
      ['dump', 'badging', apk],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        throw TimeoutException('Parse timeout');
      },
    );

    final end = DateTime.now();
    var exitCode = result.exitCode;
    final cost = end.difference(start).inMilliseconds;
    log.info("getApkInfo: end exitCode=$exitCode, cost=${cost}ms");

    if (exitCode == 0) {
      parseApkInfoFromOutput(result.stdout.toString(), apkInfo);

      final iconImage = await apkInfo.loadIcon();
      if (iconImage != null) {
        apkInfo.mainIconImage ??= iconImage;
      }

      // 如果启用了签名检查，获取签名信息
      if (Config.enableSignature.value) {
        try {
          final signInfo = await getSignatureInfo(apk);
          apkInfo.signatureInfo = signInfo;
        } catch (e) {
          log.info("getApkInfo: 获取签名信息失败: $e");
          apkInfo.signatureInfo = "获取签名信息失败: $e";
        }
      }

      return apkInfo;
    }
  } catch (e) {
    log.info("getApkInfo: error=$e");
  }

  return null;
}

Future<String> getSignatureInfo(String apkPath) async {
  final apksigner = CommandTools.findApkSignerPath();
  if (apksigner == null || apksigner.isEmpty) {
    throw Exception(t.parse.please_set_path(name: "apksigner"));
  }

  try {
    final result = await Process.run(
      apksigner,
      ['verify', '--print-certs', '--verbose', apkPath],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode == 0) {
      return result.stdout.toString();
    } else {
      throw Exception('获取签名失败: ${result.stderr}');
    }
  } catch (e) {
    log.warning('getSignatureInfo: 获取签名信息失败: $e');
    rethrow;
  }
}

void parseApkInfoFromOutput(String output, ApkInfo apkInfo) {
  apkInfo.originalText = output;
  final lines = output.split("\n");
  for (final (index, item) in lines.indexed) {
    log.finer("parseApkInfoFromOutput: [$index] $item");
    apkInfo.parseLine(item);
  }
  log.fine("parseApkInfoFromOutput: apkInfo=$apkInfo");
}

final _kNoneSingleQuotePattern = RegExp(r"[^']");

extension StringExt on String {
  // 去除前后的单引号
  String trimSQ() {
    final start = indexOf(_kNoneSingleQuotePattern);
    final end = lastIndexOf(_kNoneSingleQuotePattern);
    return substring(start < 0 ? 0 : start, end < 0 ? length : end + 1);
  }
}

class ApkInfo {
  String apkPath = "";
  int apkSize = 0;
  bool isXapk = false; // 是否为XAPK格式
  String? archiveType; // XAPK/APKM/APKS

  String? packageName;
  int? versionCode;
  String? versionName;
  String? platformBuildVersionName;
  int? platformBuildVersionCode;
  int? compileSdkVersion;
  String? compileSdkVersionCodename;
  int? sdkVersion;
  int? targetSdkVersion;
  String? label;
  String? mainIconPath; // 主图标路径
  Image? mainIconImage;
  Map<String, String> labels = {};
  List<String> usesPermissions = [];
  Map<String, String> icons = {};
  Component application = Component();
  List<Component> launchableActivity = [];
  List<String> userFeatures = [];
  List<String> userFeaturesNotRequired = [];
  List<String> userImpliedFeatures = [];
  List<String> supportsScreens = [];
  List<String> locales = [];
  List<String> densities = [];
  bool? supportsAnyDensity;
  List<String> nativeCodes = [];

  List<String> others = [];
  String signatureInfo = "";

  // 文件哈希值
  String? md5Hash;
  String? sha1Hash;

  // XAPK 相关信息
  String? xapkName;
  List<String> splitConfigs = [];
  List<String> splitApks = [];
  List<String> archiveApks = [];
  List<String> obbFiles = [];
  int? totalSize;

  // 原始文本
  String originalText = "";

  (String, String) parseToKeyValue(String line, String separator) {
    final pos = line.indexOf(separator);
    if (pos != -1) {
      final key = line.substring(0, pos).trim();
      final value = line.substring(pos + 1).trim();
      return (key, value);
    }
    return (line.trim(), "");
  }

  (String, String) parseLineToKeyValue(String line) {
    return parseToKeyValue(line, ":");
  }

  (String, String) parseValueToKeyValue(String line) {
    return parseToKeyValue(line, "=");
  }

  String? parseString(String line) {
    final items = line.split(":");
    if (items.length == 2) {
      return items[1].trim();
    } else {
      others.add(line);
    }
    return null;
  }

  int? parseInt(String value) {
    return int.tryParse(value.trimSQ());
  }

  String parseValueForName(String text) {
    final (_, value) = parseValueToKeyValue(text);
    return value.trimSQ();
  }

  void parseLine(String line) {
    final (key, value) = parseLineToKeyValue(line);
    switch (key) {
      case "package":
        parsePackage(value);
        break;
      case "sdkVersion":
      case "minSdkVersion":
        sdkVersion = parseInt(value);
        break;
      case "targetSdkVersion":
        targetSdkVersion = parseInt(value);
        break;
      case "application-label":
        label = value.trimSQ();
        break;
      case "uses-permission":
        usesPermissions.add(parseValueForName(value));
        break;
      case "application":
        parseComponent(value, application);
        // 从application中获取主图标
        if (mainIconPath == null && application.icon != null) {
          mainIconPath = application.icon;
        }
        break;
      case "launchable-activity":
        final component = Component();
        parseComponent(value, component);
        launchableActivity.add(component);
        // 如果没有主图标且launchable-activity有图标，则使用它
        if (mainIconPath == null && component.icon != null) {
          mainIconPath = component.icon;
        }
        break;
      case "supports-screens":
        parseStringList(value, supportsScreens);
        break;
      case "locales":
        parseStringList(value, locales);
        break;
      case "densities":
        parseStringList(value, densities);
        break;
      case "supports-any-density":
        supportsAnyDensity = value.trimSQ() == "true";
        break;
      case "native-code":
        parseStringList(value, nativeCodes);
        break;
      default:
        {
          if (key.startsWith("application-label-")) {
            labels[key.substring("application-label-".length + 1)] =
                value.trimSQ();
          } else if (key.startsWith("application-icon-")) {
            icons[key.substring("application-icon-".length)] = value.trimSQ();
          } else {
            others.add(line);
          }
          break;
        }
    }
  }

  void parsePackage(String text) {
    final items = text.split(" ");
    for (final item in items) {
      final (key, value) = parseValueToKeyValue(item);
      switch (key) {
        case "name":
          packageName = value.trimSQ();
          break;
        case "versionCode":
          versionCode = parseInt(value);
          break;
        case "versionName":
          versionName = value.trimSQ();
          break;
        case "platformBuildVersionName":
          platformBuildVersionName = value.trimSQ();
          break;
        case "platformBuildVersionCode":
          platformBuildVersionCode = parseInt(value);
          break;
        case "compileSdkVersion":
          compileSdkVersion = parseInt(value);
          break;
        case "compileSdkVersionCodename":
          compileSdkVersionCodename = value.trimSQ();
          break;
      }
    }
  }

  void parseComponent(String value, Component component) {
    final items = value.split(" ");
    for (final item in items) {
      final (key, value) = parseValueToKeyValue(item);
      switch (key) {
        case "name":
          component.name = value.trimSQ();
          break;
        case "label":
          component.label = value.trimSQ();
          break;
        case "icon":
          component.icon = value.trimSQ();
          break;
      }
    }
  }

  void parseStringList(String value, List<String> out) {
    final items = value.split(" ");
    for (final item in items) {
      out.add(item.trimSQ());
    }
  }

  // 从 application-icon-* 中按密度从大到小排列
  List<String> _buildIconCandidates() {
    final entries = <MapEntry<int, String>>[];
    icons.forEach((key, value) {
      final tmp = int.tryParse(key);
      if (tmp != null) {
        entries.add(MapEntry(tmp, value));
      }
      log.finer("_buildIconCandidates: key=$key, value=$value");
    });

    entries.sort((a, b) => b.key.compareTo(a.key));
    return entries.map((e) => e.value).toList();
  }

  bool _isBitmapIcon(String path) {
    return path.endsWith('.webp') || path.endsWith('.png');
  }

  bool _isBitmapPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.webp') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg');
  }

  bool _isXmlPath(String path) {
    return path.toLowerCase().endsWith('.xml');
  }

  Future<Image?> _decodeImageData(Uint8List data) async {
    try {
      final codec = await instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  int _unknownPathScore(String candidate) {
    final lower = candidate.toLowerCase();
    var score = 0;
    if (lower.contains('mipmap')) score += 300;
    if (lower.contains('drawable')) score += 220;
    if (lower.contains('launcher')) score += 180;
    if (_isBitmapPath(lower)) score += 200;
    if (_isXmlPath(lower)) score += 120;
    if (lower.contains('-xxxhdpi')) score += 90;
    if (lower.contains('-xxhdpi')) score += 80;
    if (lower.contains('-xhdpi')) score += 70;
    if (lower.contains('-hdpi')) score += 60;
    if (lower.contains('-mdpi')) score += 50;
    return score;
  }

  List<String> _findUnknownCandidatePaths(ZipHelper zip, String candidate) {
    final raw = candidate.trim();
    if (raw.isEmpty) return const [];
    final normalized = raw.replaceAll('\\', '/');
    final files = zip.listFiles();
    final result = <String>{};
    if (files.contains(normalized)) {
      result.add(normalized);
    }
    if (normalized.startsWith('/')) {
      final tmp = normalized.substring(1);
      if (files.contains(tmp)) {
        result.add(tmp);
      }
    }
    final base = path.basename(normalized).toLowerCase();
    for (final file in files) {
      final fileLower = file.toLowerCase();
      final fileBase = path.basename(fileLower);
      if (fileBase == base || fileLower.endsWith('/$base')) {
        result.add(file);
      }
    }
    final sorted = result.toList();
    sorted.sort((a, b) => _unknownPathScore(b).compareTo(_unknownPathScore(a)));
    return sorted;
  }

  /// 加载APK图标
  /// 返回图标的字节数据，如果加载失败返回null
  Future<Image?> loadIcon() async {
    if (mainIconPath == null || mainIconPath!.isEmpty) {
      if (icons.isEmpty) {
        return null;
      }
    }

    final zip = ZipHelper();
    try {
      zip.open(apkPath);
      AdaptiveIconRenderer? adaptiveIconRenderer;
      final aaptPath = CommandTools.findAapt2Path();

      final candidates = <String>[];
      if (mainIconPath != null && mainIconPath!.isNotEmpty) {
        candidates.add(mainIconPath!);
      }
      candidates.addAll(_buildIconCandidates());
      final uniqueCandidates = <String>[];
      final seenCandidates = <String>{};
      for (final item in candidates) {
        if (seenCandidates.add(item)) {
          uniqueCandidates.add(item);
        }
      }
      final prioritizedCandidates = <String>[];
      final prioritizedSeen = <String>{};
      for (final iconPath in uniqueCandidates) {
        if (_isXmlPath(iconPath) && aaptPath != null && aaptPath.isNotEmpty) {
          adaptiveIconRenderer ??= AdaptiveIconRenderer(
            apkPath: apkPath,
            aaptPath: aaptPath,
            zip: zip,
          );
          final resourceLinkedBitmaps = await adaptiveIconRenderer
              .findBitmapAlternativesForPath(iconPath);
          if (resourceLinkedBitmaps.isNotEmpty) {
            log.fine(
                'loadIcon: XML 资源同条目位图候选($iconPath) => ${resourceLinkedBitmaps.join(", ")}');
          }
          for (final bitmap in resourceLinkedBitmaps) {
            if (prioritizedSeen.add(bitmap)) {
              prioritizedCandidates.add(bitmap);
            }
          }
        }
        if (prioritizedSeen.add(iconPath)) {
          prioritizedCandidates.add(iconPath);
        }
      }
      log.info('loadIcon: candidates=${prioritizedCandidates.join(", ")}');

      for (final iconPath in prioritizedCandidates) {
        if (_isBitmapIcon(iconPath)) {
          final data = await zip.readFileContent(iconPath);
          if (data != null) {
            final image = await _decodeImageData(data);
            if (image != null) {
              log.info('loadIcon: 使用图标: $iconPath');
              return image;
            }
          }
          log.info('loadIcon: 找不到图标文件: $iconPath');
        } else if (iconPath.endsWith('.xml')) {
          if (aaptPath == null || aaptPath.isEmpty) {
            log.info('loadIcon: aapt2 未配置，无法解析 XML 图标: $iconPath');
            continue;
          }
          adaptiveIconRenderer ??= AdaptiveIconRenderer(
            apkPath: apkPath,
            aaptPath: aaptPath,
            zip: zip,
          );
          final image = await adaptiveIconRenderer.render(iconPath);
          if (image != null) {
            log.info('loadIcon: 使用 XML 图标: $iconPath');
            return image;
          }
          log.info('loadIcon: XML 图标解析失败: $iconPath');
        } else {
          if (aaptPath != null && aaptPath.isNotEmpty) {
            adaptiveIconRenderer ??= AdaptiveIconRenderer(
              apkPath: apkPath,
              aaptPath: aaptPath,
              zip: zip,
            );
            final rendered = await adaptiveIconRenderer.render(iconPath);
            if (rendered != null) {
              log.info('loadIcon: 使用资源引用图标: $iconPath');
              return rendered;
            }
          }

          final resolvedPaths = _findUnknownCandidatePaths(zip, iconPath);
          for (final resolved in resolvedPaths) {
            if (_isXmlPath(resolved)) {
              if (aaptPath == null || aaptPath.isEmpty) continue;
              adaptiveIconRenderer ??= AdaptiveIconRenderer(
                apkPath: apkPath,
                aaptPath: aaptPath,
                zip: zip,
              );
              final rendered = await adaptiveIconRenderer.render(resolved);
              if (rendered != null) {
                log.info('loadIcon: 使用反查XML图标: $resolved (from: $iconPath)');
                return rendered;
              }
              continue;
            }

            final data = await zip.readFileContent(resolved);
            if (data == null || data.isEmpty) continue;
            final image = await _decodeImageData(data);
            if (image != null) {
              log.info('loadIcon: 使用反查位图图标: $resolved (from: $iconPath)');
              return image;
            }
          }
          log.info('loadIcon: 不支持的图标格式: $iconPath');
        }
      }

      // 兜底：从 APK 中启发式扫描可能的启动图标资源
      final fallbackCandidates = zip
          .listFiles()
          .where((e) {
            final lower = e.toLowerCase();
            return lower.contains('mipmap') ||
                (lower.contains('drawable') && lower.contains('launcher'));
          })
          .toSet()
          .toList()
        ..sort((a, b) => _unknownPathScore(b).compareTo(_unknownPathScore(a)));

      for (final candidate in fallbackCandidates) {
        if (_isXmlPath(candidate)) {
          if (aaptPath == null || aaptPath.isEmpty) continue;
          adaptiveIconRenderer ??= AdaptiveIconRenderer(
            apkPath: apkPath,
            aaptPath: aaptPath,
            zip: zip,
          );
          final rendered = await adaptiveIconRenderer.render(candidate);
          if (rendered != null) {
            log.info('loadIcon: 使用兜底XML图标: $candidate');
            return rendered;
          }
          continue;
        }
        final data = await zip.readFileContent(candidate);
        if (data == null || data.isEmpty) continue;
        final image = await _decodeImageData(data);
        if (image != null) {
          log.info('loadIcon: 使用兜底位图图标: $candidate');
          return image;
        }
      }

      log.info('loadIcon: 未找到可用图标');
    } catch (e) {
      log.warning('loadIcon: 加载图标失败: $e');
    } finally {
      zip.close();
    }
    return null;
  }

  @override
  String toString() {
    return 'ApkInfo{apkPath: $apkPath, apkSize: $apkSize, isXapk: $isXapk, archiveType: $archiveType, packageName: $packageName, versionCode: $versionCode, versionName: $versionName, platformBuildVersionName: $platformBuildVersionName, platformBuildVersionCode: $platformBuildVersionCode, compileSdkVersion: $compileSdkVersion, compileSdkVersionCodename: $compileSdkVersionCodename, sdkVersion: $sdkVersion, targetSdkVersion: $targetSdkVersion, label: $label, mainIcon: $mainIconPath, labels: $labels, usesPermissions: $usesPermissions, icons: $icons, application: $application, launchableActivity: $launchableActivity, userFeatures: $userFeatures, userFeaturesNotRequired: $userFeaturesNotRequired, userImpliedFeatures: $userImpliedFeatures, supportsScreens: $supportsScreens, locales: $locales, densities: $densities, supportsAnyDensity: $supportsAnyDensity, nativeCodes: $nativeCodes, others: $others, signatureInfo: $signatureInfo, xapkName: $xapkName, splitConfigs: $splitConfigs, splitApks: $splitApks, archiveApks: $archiveApks, obbFiles: $obbFiles, totalSize: $totalSize}';
  }

  void reset() {
    apkPath = "";
    apkSize = 0;
    isXapk = false;
    archiveType = null;
    packageName = null;
    versionCode = null;
    versionName = null;
    platformBuildVersionName = null;
    platformBuildVersionCode = null;
    compileSdkVersion = null;
    compileSdkVersionCodename = null;
    sdkVersion = null;
    targetSdkVersion = null;
    label = null;
    mainIconPath = null;
    mainIconImage = null;
    labels.clear();
    usesPermissions.clear();
    icons.clear();
    application = Component();
    launchableActivity.clear();
    userFeatures.clear();
    userFeaturesNotRequired.clear();
    userImpliedFeatures.clear();
    supportsScreens.clear();
    locales.clear();
    densities.clear();
    supportsAnyDensity = null;
    nativeCodes.clear();
    others.clear();
    signatureInfo = "";
    md5Hash = null;
    sha1Hash = null;
    xapkName = null;
    splitConfigs.clear();
    splitApks.clear();
    archiveApks.clear();
    obbFiles.clear();
    totalSize = null;
    originalText = "";
  }
}

class Component {
  String? name;
  String? label;
  String? icon;

  Component({this.name, this.label, this.icon});

  @override
  String toString() {
    return 'Component{name: $name, label: $label, icon: $icon}';
  }
}
