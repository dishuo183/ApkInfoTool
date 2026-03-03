import 'dart:convert';
import 'dart:typed_data';

import 'package:apk_info_tool/apkparser/adaptive_icon_renderer.dart';
import 'package:apk_info_tool/apkparser/binary_xml.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:xml/xml.dart' as xml;

/// 将 Android VectorDrawable XML 转换为 SVG 格式
class VectorToSvg {
  static final _binaryXmlDecompressor = BinaryXmlDecompressor();

  /// 将原始 XML 字节（可能是二进制 XML）转换为 SVG 字符串
  /// 返回 null 表示无法转换
  static String? convert(Uint8List xmlBytes) {
    try {
      final xmlText = _decodeXmlText(xmlBytes);
      final doc = xml.XmlDocument.parse(xmlText);
      final root = doc.rootElement;
      return convertElement(root);
    } catch (e) {
      log.warning('VectorToSvg.convert failed: $e');
      return null;
    }
  }

  /// 将已解析的 XML 元素转换为 SVG 字符串
  static String? convertElement(xml.XmlElement root) {
    final tag = root.name.local.toLowerCase();

    if (tag == 'vector') {
      return _convertVector(root);
    }

    if (tag == 'adaptive-icon') {
      return _convertAdaptiveIcon(root);
    }

    return null;
  }

  /// 将已解析的 adaptive-icon 数据（包含 background + foreground）转换为 SVG
  static String? convertAdaptiveIconData(AdaptiveIconSvgData data) {
    if (!data.hasContent) return null;

    // 从 foreground 或 background vector 推断 viewport 尺寸
    double viewportW = 108, viewportH = 108;
    final refVector = data.foregroundVector ?? data.backgroundVector;
    if (refVector != null) {
      viewportW = _parseDim(_attr(refVector, 'viewportWidth')) ?? 108;
      viewportH = _parseDim(_attr(refVector, 'viewportHeight')) ?? 108;
    }

    // 圆角半径：与 AdaptiveIconRenderer._defaultAdaptiveMask 一致 (size * 0.22)
    final maskSize = viewportW < viewportH ? viewportW : viewportH;
    final cornerRadius = maskSize * 0.22;

    final gradientDefs = <String>[];
    final contentBuf = StringBuffer();
    final indent = '    '; // 内容在 clip group 内，多一层缩进

    // Background 层
    if (data.backgroundColor != null) {
      final svgColor = _androidColorToSvg(data.backgroundColor!);
      if (svgColor != null) {
        contentBuf.write(
            '$indent<rect width="$viewportW" height="$viewportH" fill="${svgColor.color}"');
        if (svgColor.opacity != null && svgColor.opacity! < 1.0) {
          contentBuf.write(' fill-opacity="${svgColor.opacity}"');
        }
        contentBuf.writeln('/>');
      }
    }
    if (data.backgroundVector != null) {
      final bgVpW =
          _parseDim(_attr(data.backgroundVector!, 'viewportWidth')) ??
              viewportW;
      final bgVpH =
          _parseDim(_attr(data.backgroundVector!, 'viewportHeight')) ??
              viewportH;
      if (bgVpW != viewportW || bgVpH != viewportH) {
        contentBuf.writeln(
            '$indent<g transform="scale(${viewportW / bgVpW}, ${viewportH / bgVpH})">');
        _convertChildren(contentBuf,
            data.backgroundVector!.childElements, '$indent  ', gradientDefs);
        contentBuf.writeln('$indent</g>');
      } else {
        _convertChildren(contentBuf,
            data.backgroundVector!.childElements, indent, gradientDefs);
      }
    }

    // Foreground 层 — 应用自适应图标前景缩放（与 AdaptiveIconRenderer 渲染一致）
    if (data.foregroundVector != null) {
      final fgVpW =
          _parseDim(_attr(data.foregroundVector!, 'viewportWidth')) ??
              viewportW;
      final fgVpH =
          _parseDim(_attr(data.foregroundVector!, 'viewportHeight')) ??
              viewportH;
      final fgScale = data.foregroundScale;
      final needsFgScale = (fgScale - 1.0).abs() > 1e-6;
      final needsVpScale = fgVpW != viewportW || fgVpH != viewportH;

      var innerIndent = indent;
      // 自适应前景缩放（从视口中心缩放）
      if (needsFgScale) {
        final cx = viewportW / 2;
        final cy = viewportH / 2;
        contentBuf.writeln(
            '$indent<g transform="translate($cx, $cy) scale($fgScale) translate(${-cx}, ${-cy})">');
        innerIndent = '$indent  ';
      }
      if (needsVpScale) {
        contentBuf.writeln(
            '$innerIndent<g transform="scale(${viewportW / fgVpW}, ${viewportH / fgVpH})">');
        _convertChildren(contentBuf,
            data.foregroundVector!.childElements, '$innerIndent  ', gradientDefs);
        contentBuf.writeln('$innerIndent</g>');
      } else {
        _convertChildren(contentBuf,
            data.foregroundVector!.childElements, innerIndent, gradientDefs);
      }
      if (needsFgScale) {
        contentBuf.writeln('$indent</g>');
      }
    }

    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.write('<svg xmlns="http://www.w3.org/2000/svg"');
    buf.write(' width="$viewportW" height="$viewportH"');
    buf.write(' viewBox="0 0 $viewportW $viewportH"');
    buf.writeln('>');

    // <defs>: 圆角裁剪 + 渐变定义
    buf.writeln('  <defs>');
    buf.writeln(
        '    <clipPath id="adaptive_clip">');
    buf.writeln(
        '      <rect width="$viewportW" height="$viewportH" rx="$cornerRadius" ry="$cornerRadius"/>');
    buf.writeln('    </clipPath>');
    for (final def in gradientDefs) {
      buf.writeln(def);
    }
    buf.writeln('  </defs>');

    // 所有内容在圆角裁剪区域内渲染
    buf.writeln('  <g clip-path="url(#adaptive_clip)">');
    buf.write(contentBuf);
    buf.writeln('  </g>');

    buf.writeln('</svg>');
    return buf.toString();
  }

  static String _decodeXmlText(Uint8List bytes) {
    if (_looksLikeBinaryXml(bytes)) {
      try {
        return _binaryXmlDecompressor.decompressXml(bytes);
      } catch (_) {}
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static bool _looksLikeBinaryXml(Uint8List bytes) {
    if (bytes.length < 8) return false;
    // Android binary XML magic: 0x0003 (little-endian)
    return bytes[0] == 0x03 && bytes[1] == 0x00;
  }

  static String? _convertAdaptiveIcon(xml.XmlElement root) {
    // 尝试从 foreground 层提取 vector drawable
    final foreground = _findDirectChild(root, 'foreground');
    if (foreground != null) {
      // foreground 可能直接包含 <vector> 子元素
      final vectorChild = _findDirectChild(foreground, 'vector');
      if (vectorChild != null) {
        return _convertVector(vectorChild);
      }
    }

    // 尝试从 background 层提取
    final background = _findDirectChild(root, 'background');
    if (background != null) {
      final vectorChild = _findDirectChild(background, 'vector');
      if (vectorChild != null) {
        return _convertVector(vectorChild);
      }
    }

    return null;
  }

  static String _convertVector(xml.XmlElement vector) {
    final viewportWidth = _parseDim(_attr(vector, 'viewportWidth')) ?? 24;
    final viewportHeight = _parseDim(_attr(vector, 'viewportHeight')) ?? 24;
    // 使用 viewport 尺寸作为 SVG 的 width/height，
    // 因为二进制 XML 中 dimension 类型（dp）的值可能被错误放大
    final width = viewportWidth;
    final height = viewportHeight;
    final alpha = _parseDim(_attr(vector, 'alpha'));

    // 收集渐变定义，稍后统一输出到 <defs> 中
    final gradientDefs = <String>[];
    final contentBuf = StringBuffer();
    _convertChildren(contentBuf, vector.childElements, '  ', gradientDefs);

    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.write('<svg xmlns="http://www.w3.org/2000/svg"');
    buf.write(' width="$width" height="$height"');
    buf.write(' viewBox="0 0 $viewportWidth $viewportHeight"');
    if (alpha != null && alpha < 1.0) {
      buf.write(' opacity="$alpha"');
    }
    buf.writeln('>');

    if (gradientDefs.isNotEmpty) {
      buf.writeln('  <defs>');
      for (final def in gradientDefs) {
        buf.writeln(def);
      }
      buf.writeln('  </defs>');
    }

    buf.write(contentBuf);
    buf.writeln('</svg>');
    return buf.toString();
  }

  static void _convertChildren(
    StringBuffer buf,
    Iterable<xml.XmlElement> elements,
    String indent,
    List<String> gradientDefs,
  ) {
    int clipId = 0;
    for (final child in elements) {
      final tag = child.name.local.toLowerCase();
      switch (tag) {
        case 'group':
          _convertGroup(buf, child, indent, gradientDefs);
          break;
        case 'path':
          _convertPath(buf, child, indent, gradientDefs);
          break;
        case 'clip-path':
          _convertClipPath(buf, child, indent, clipId++);
          break;
      }
    }
  }

  static void _convertGroup(
    StringBuffer buf,
    xml.XmlElement group,
    String indent,
    List<String> gradientDefs,
  ) {
    final transforms = <String>[];

    final translateX = _parseDim(_attr(group, 'translateX'));
    final translateY = _parseDim(_attr(group, 'translateY'));
    if ((translateX ?? 0) != 0 || (translateY ?? 0) != 0) {
      transforms.add('translate(${translateX ?? 0}, ${translateY ?? 0})');
    }

    final pivotX = _parseDim(_attr(group, 'pivotX'));
    final pivotY = _parseDim(_attr(group, 'pivotY'));
    final rotation = _parseDim(_attr(group, 'rotation'));

    if (rotation != null && rotation != 0) {
      transforms.add('rotate($rotation, ${pivotX ?? 0}, ${pivotY ?? 0})');
    }

    final scaleX = _parseDim(_attr(group, 'scaleX'));
    final scaleY = _parseDim(_attr(group, 'scaleY'));
    if (scaleX != null || scaleY != null) {
      final sx = scaleX ?? 1;
      final sy = scaleY ?? 1;
      if (sx != 1 || sy != 1) {
        if (pivotX != null || pivotY != null) {
          final px = pivotX ?? 0;
          final py = pivotY ?? 0;
          transforms.add(
              'translate($px, $py) scale($sx, $sy) translate(${-px}, ${-py})');
        } else {
          transforms.add('scale($sx, $sy)');
        }
      }
    }

    final alpha = _parseDim(_attr(group, 'alpha'));

    buf.write('$indent<g');
    if (transforms.isNotEmpty) {
      buf.write(' transform="${transforms.join(' ')}"');
    }
    if (alpha != null && alpha < 1.0) {
      buf.write(' opacity="$alpha"');
    }
    buf.writeln('>');

    _convertChildren(buf, group.childElements, '$indent  ', gradientDefs);

    buf.writeln('$indent</g>');
  }

  static void _convertPath(
    StringBuffer buf,
    xml.XmlElement element,
    String indent,
    List<String> gradientDefs,
  ) {
    final pathData = _attr(element, 'pathData');
    if (pathData == null || pathData.isEmpty) return;

    final fillColor = _attr(element, 'fillColor');
    final fillAlpha = _parseDim(_attr(element, 'fillAlpha'));
    final strokeColor = _attr(element, 'strokeColor');
    final strokeWidth = _parseDim(_attr(element, 'strokeWidth'));
    final strokeAlpha = _parseDim(_attr(element, 'strokeAlpha'));
    final fillType = (_attr(element, 'fillType') ?? '').toLowerCase();
    final strokeLineCap = _attr(element, 'strokeLineCap');
    final strokeLineJoin = _attr(element, 'strokeLineJoin');
    final strokeMiterLimit = _parseDim(_attr(element, 'strokeMiterLimit'));
    final name = _attr(element, 'name');

    // 检查是否有嵌入的渐变定义（由 AdaptiveIconRenderer 解析注入）
    final gradientChild = _findDirectChild(element, 'resolvedGradient');
    String? gradientFillRef;
    if (gradientChild != null) {
      final gradientId = 'gradient_${gradientDefs.length}';
      final gradientSvg = _buildSvgGradient(gradientChild, gradientId);
      if (gradientSvg != null) {
        gradientDefs.add(gradientSvg);
        gradientFillRef = 'url(#$gradientId)';
      }
    }

    buf.write('$indent<path');

    if (name != null && name.isNotEmpty) {
      buf.write(' id="${_escapeXml(name)}"');
    }

    buf.write(' d="${_escapeXml(pathData)}"');

    // Fill
    if (gradientFillRef != null) {
      // 渐变填充
      buf.write(' fill="$gradientFillRef"');
      if (fillAlpha != null && fillAlpha < 1.0) {
        buf.write(' fill-opacity="$fillAlpha"');
      }
    } else if (fillColor != null && fillColor.isNotEmpty && _isColor(fillColor)) {
      final svgColor = _androidColorToSvg(fillColor);
      if (svgColor != null) {
        buf.write(' fill="${svgColor.color}"');
        if (svgColor.opacity != null) {
          final combinedOpacity = (svgColor.opacity ?? 1.0) * (fillAlpha ?? 1.0);
          if (combinedOpacity < 1.0) {
            buf.write(' fill-opacity="$combinedOpacity"');
          }
        } else if (fillAlpha != null && fillAlpha < 1.0) {
          buf.write(' fill-opacity="$fillAlpha"');
        }
      }
    } else if (fillColor == null || fillColor.isEmpty) {
      // Android 默认 fill 为黑色，SVG 也是，但如果有 stroke 且无 fill 则设为 none
      if (strokeColor != null && strokeColor.isNotEmpty) {
        buf.write(' fill="none"');
      }
    } else {
      buf.write(' fill="none"');
    }

    // Fill rule
    if (fillType == 'evenodd' || fillType == '1' || fillType == '0x1') {
      buf.write(' fill-rule="evenodd"');
    }

    // Stroke
    if (strokeColor != null &&
        strokeColor.isNotEmpty &&
        _isColor(strokeColor)) {
      final svgColor = _androidColorToSvg(strokeColor);
      if (svgColor != null && (strokeWidth ?? 0) > 0) {
        buf.write(' stroke="${svgColor.color}"');
        buf.write(' stroke-width="$strokeWidth"');
        if (svgColor.opacity != null || (strokeAlpha != null && strokeAlpha < 1.0)) {
          final combinedOpacity = (svgColor.opacity ?? 1.0) * (strokeAlpha ?? 1.0);
          if (combinedOpacity < 1.0) {
            buf.write(' stroke-opacity="$combinedOpacity"');
          }
        }
        if (strokeLineCap != null) {
          buf.write(' stroke-linecap="$strokeLineCap"');
        }
        if (strokeLineJoin != null) {
          buf.write(' stroke-linejoin="$strokeLineJoin"');
        }
        if (strokeMiterLimit != null && strokeMiterLimit > 0) {
          buf.write(' stroke-miterlimit="$strokeMiterLimit"');
        }
      }
    }

    buf.writeln('/>');
  }

  /// 将嵌入的渐变元素转换为 SVG 渐变定义
  static String? _buildSvgGradient(xml.XmlElement gradient, String id) {
    final type = _attr(gradient, 'type') ?? 'linear';
    final stops = <String>[];

    for (final stop
        in gradient.childElements.where((e) => e.name.local == 'stop')) {
      final offset = _parseDim(_attr(stop, 'offset')) ?? 0;
      final color = _attr(stop, 'color') ?? '#000000';
      final svgColor = _androidColorToSvg(color);
      if (svgColor != null) {
        final stopBuf = StringBuffer('      <stop offset="$offset"');
        stopBuf.write(' stop-color="${svgColor.color}"');
        if (svgColor.opacity != null && svgColor.opacity! < 1.0) {
          stopBuf.write(' stop-opacity="${svgColor.opacity}"');
        }
        stopBuf.write('/>');
        stops.add(stopBuf.toString());
      }
    }

    if (stops.isEmpty) return null;

    final buf = StringBuffer();
    if (type == 'linear') {
      final x1 = _attr(gradient, 'startX') ?? '0';
      final y1 = _attr(gradient, 'startY') ?? '0';
      final x2 = _attr(gradient, 'endX') ?? '0';
      final y2 = _attr(gradient, 'endY') ?? '0';
      buf.writeln(
          '    <linearGradient id="$id" x1="$x1" y1="$y1" x2="$x2" y2="$y2" gradientUnits="userSpaceOnUse">');
      for (final stop in stops) {
        buf.writeln(stop);
      }
      buf.write('    </linearGradient>');
    } else if (type == 'radial') {
      final cx = _attr(gradient, 'centerX') ?? '0';
      final cy = _attr(gradient, 'centerY') ?? '0';
      final r = _attr(gradient, 'gradientRadius') ?? '0';
      buf.writeln(
          '    <radialGradient id="$id" cx="$cx" cy="$cy" r="$r" gradientUnits="userSpaceOnUse">');
      for (final stop in stops) {
        buf.writeln(stop);
      }
      buf.write('    </radialGradient>');
    } else {
      // sweep 渐变 SVG 不原生支持，跳过
      return null;
    }

    return buf.toString();
  }

  static void _convertClipPath(
    StringBuffer buf,
    xml.XmlElement element,
    String indent,
    int id,
  ) {
    final pathData = _attr(element, 'pathData');
    if (pathData == null || pathData.isEmpty) return;

    final clipId = 'clip_$id';
    buf.writeln('$indent<defs>');
    buf.writeln('$indent  <clipPath id="$clipId">');
    buf.writeln('$indent    <path d="${_escapeXml(pathData)}"/>');
    buf.writeln('$indent  </clipPath>');
    buf.writeln('$indent</defs>');
    // 后续的兄弟元素应被此 clip-path 裁剪，但简单转换中无法完美处理
    // 在大多数情况下，clip-path 和 path 在同一个 group 内
  }

  // ──────────── 辅助方法 ────────────

  static String? _attr(xml.XmlElement? element, String localName) {
    if (element == null) return null;
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) {
        return attribute.value;
      }
    }
    return null;
  }

  static xml.XmlElement? _findDirectChild(xml.XmlElement element, String name) {
    for (final child in element.childElements) {
      if (child.name.local.toLowerCase() == name.toLowerCase()) {
        return child;
      }
    }
    return null;
  }

  static double? _parseDim(String? value) {
    if (value == null || value.isEmpty) return null;
    // 去除 dp/dip/sp/px 后缀
    final cleaned = value
        .replaceAll(RegExp(r'(dp|dip|sp|px)$', caseSensitive: false), '')
        .trim();
    return double.tryParse(cleaned);
  }

  static bool _isColor(String value) {
    return value.startsWith('#');
  }

  /// 将 Android 颜色 (#AARRGGBB 或 #RRGGBB) 转换为 SVG 格式
  static _SvgColor? _androidColorToSvg(String androidColor) {
    if (!androidColor.startsWith('#')) return null;
    final hex = androidColor.substring(1);

    switch (hex.length) {
      case 3: // #RGB
        return _SvgColor('#$hex', null);
      case 4: // #ARGB
        final a = int.tryParse(hex[0] + hex[0], radix: 16);
        final rgb = hex.substring(1);
        final expandedRgb = '${rgb[0]}${rgb[0]}${rgb[1]}${rgb[1]}${rgb[2]}${rgb[2]}';
        return _SvgColor('#$expandedRgb', a != null ? a / 255.0 : null);
      case 6: // #RRGGBB
        return _SvgColor('#$hex', null);
      case 8: // #AARRGGBB → SVG #RRGGBB + opacity
        final a = int.tryParse(hex.substring(0, 2), radix: 16);
        final rgb = hex.substring(2);
        return _SvgColor('#$rgb', a != null ? a / 255.0 : null);
      default:
        return null;
    }
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}

class _SvgColor {
  final String color;
  final double? opacity;
  _SvgColor(this.color, this.opacity);
}
