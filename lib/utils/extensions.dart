import 'package:flutter/material.dart';

/// 颜色扩展，简化透明度设置
extension ColorOpacity on Color {
  /// 返回带透明度的颜色
  /// [value] 透明度值，范围 0.0 - 1.0
  /// 示例: `Colors.red.o(0.5)` 代替 `Colors.red.withAlpha((0.5 * 255).toInt())`
  Color o(double value) {
    assert(value >= 0.0 && value <= 1.0, '透明度必须在 0.0 到 1.0 之间');
    return withAlpha((value * 255).round());
  }
}

/// BuildContext 扩展
extension BuildContextExtension on BuildContext {
  /// 获取主题数据
  ThemeData get theme => Theme.of(this);

  /// 获取颜色方案
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  /// 获取媒体查询
  MediaQueryData get mediaQuery => MediaQuery.of(this);

  /// 屏幕宽度
  double get screenWidth => mediaQuery.size.width;

  /// 屏幕高度
  double get screenHeight => mediaQuery.size.height;

  /// 是否是深色模式
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  /// 显示 SnackBar 的快捷方法
  void showSnackBar(String message, {Color? backgroundColor, Duration? duration}) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: duration ?? const Duration(seconds: 2),
      ),
    );
  }

  /// 显示错误 SnackBar
  void showErrorSnackBar(String message) {
    showSnackBar(message, backgroundColor: Colors.red);
  }

  /// 显示成功 SnackBar
  void showSuccessSnackBar(String message) {
    showSnackBar(message, backgroundColor: Colors.green);
  }
}

/// String 扩展
extension StringExtension on String {
  /// 限制字符串长度，超出部分显示省略号
  String truncate(int maxLength, {String suffix = '...'}) {
    if (length <= maxLength) return this;
    return '${substring(0, maxLength)}$suffix';
  }

  /// 获取文件扩展名（包含点）
  String get fileExtension {
    final lastDot = lastIndexOf('.');
    if (lastDot > 0 && lastDot < length - 1) {
      return substring(lastDot);
    }
    return '';
  }

  /// 获取文件名（不含扩展名）
  String get fileNameWithoutExtension {
    final name = split('/').last;
    final lastDot = name.lastIndexOf('.');
    if (lastDot > 0) {
      return name.substring(0, lastDot);
    }
    return name;
  }
}

/// Duration 扩展
extension DurationExtension on Duration {
  /// 格式化为易读的时间字符串
  String get formatted {
    if (inSeconds < 60) return '${inSeconds}秒';
    if (inMinutes < 60) return '${inMinutes}分钟';
    return '${inHours}小时 ${inMinutes % 60}分钟';
  }
}
