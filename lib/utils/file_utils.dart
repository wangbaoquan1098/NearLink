import 'package:flutter/material.dart';
import 'package:mime/mime.dart';

/// 文件类型工具类
/// 提供统一的文件类型检测、图标获取、大小格式化等功能
class FileUtils {
  FileUtils._(); // 私有构造函数，阻止实例化

  /// 图片扩展名列表
  static const List<String> _imageExtensions = [
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'
  ];

  /// 视频扩展名列表
  static const List<String> _videoExtensions = [
    'mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv'
  ];

  /// 音频扩展名列表
  static const List<String> _audioExtensions = [
    'mp3', 'aac', 'wav', 'flac', 'ogg', 'm4a'
  ];

  /// 文档扩展名列表
  static const Map<String, List<String>> _documentTypes = {
    'pdf': ['pdf'],
    'word': ['doc', 'docx'],
    'excel': ['xls', 'xlsx', 'csv'],
    'ppt': ['ppt', 'pptx'],
    'text': ['txt', 'md', 'rtf'],
    'code': ['dart', 'java', 'kt', 'swift', 'js', 'html', 'css', 'json', 'xml'],
  };

  /// 根据 MIME 类型获取文件图标
  static IconData getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('document')) {
      return Icons.description;
    }
    if (mimeType.contains('sheet') || mimeType.contains('excel')) {
      return Icons.table_chart;
    }
    if (mimeType.contains('presentation') || mimeType.contains('powerpoint')) {
      return Icons.slideshow;
    }
    if (mimeType.contains('text')) return Icons.text_snippet;
    if (mimeType.contains('zip') || mimeType.contains('compressed')) {
      return Icons.folder_zip;
    }
    return Icons.insert_drive_file;
  }

  /// 根据文件名获取文件图标
  static IconData getFileIconByName(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';

    if (_imageExtensions.contains(ext)) return Icons.image;
    if (_videoExtensions.contains(ext)) return Icons.video_file;
    if (_audioExtensions.contains(ext)) return Icons.audio_file;
    if (_documentTypes['pdf']!.contains(ext)) return Icons.picture_as_pdf;
    if (_documentTypes['word']!.contains(ext)) return Icons.description;
    if (_documentTypes['excel']!.contains(ext)) return Icons.table_chart;
    if (_documentTypes['ppt']!.contains(ext)) return Icons.slideshow;
    if (_documentTypes['text']!.contains(ext)) return Icons.text_snippet;
    if (ext == 'zip' || ext == 'rar' || ext == '7z') return Icons.folder_zip;
    if (_documentTypes['code']!.contains(ext)) return Icons.code;

    return Icons.insert_drive_file;
  }

  /// 判断是否为图片文件
  static bool isImageFile(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';
    return _imageExtensions.contains(ext);
  }

  /// 判断是否为视频文件
  static bool isVideoFile(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';
    return _videoExtensions.contains(ext);
  }

  /// 判断是否为音频文件
  static bool isAudioFile(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';
    return _audioExtensions.contains(ext);
  }

  /// 判断是否为文档文件
  static bool isDocumentFile(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';
    return _documentTypes.values.any((list) => list.contains(ext));
  }

  /// 获取 MIME 类型
  static String getMimeType(String fileName) {
    return lookupMimeType(fileName) ?? 'application/octet-stream';
  }

  /// 格式化文件大小
  /// 返回易读的文件大小字符串，如 "2.5 MB"
  static String formatFileSize(int bytes, {int decimals = 1}) {
    if (bytes < 0) return '未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(decimals)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(decimals)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(decimals)} GB';
  }

  /// 格式化传输速度
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 0) return '--';
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// 计算预计剩余时间
  static String estimateRemainingTime({
    required double progress,
    required DateTime startTime,
  }) {
    if (progress <= 0 || progress >= 1) return '--';

    final elapsed = DateTime.now().difference(startTime);
    final total = elapsed.inMilliseconds / progress;
    final remaining = total - elapsed.inMilliseconds;

    if (remaining < 1000) return '< 1 秒';
    if (remaining < 60000) return '${(remaining / 1000).ceil()} 秒';
    return '${(remaining / 60000).ceil()} 分钟';
  }

  /// 计算传输速度
  static String calculateSpeed({
    required int fileSize,
    required double progress,
    required DateTime startTime,
  }) {
    if (progress <= 0) return '-- KB/s';

    final elapsed = DateTime.now().difference(startTime);
    if (elapsed.inSeconds == 0) return '-- KB/s';

    final bytesPerSecond = (fileSize * progress) / elapsed.inSeconds;
    return formatSpeed(bytesPerSecond);
  }
}

/// 传输状态工具类
class TransferStatusUtils {
  TransferStatusUtils._();

  /// 根据传输状态获取对应的颜色
  static Color getStatusColor(String status) {
    switch (status) {
      case 'transferring':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'failed':
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  /// 根据传输状态获取对应的文字
  static String getStatusText(String status) {
    switch (status) {
      case 'idle':
        return '等待开始';
      case 'connecting':
        return '连接中...';
      case 'handshaking':
        return '握手...';
      case 'transferring':
        return '传输中...';
      case 'completed':
        return '传输完成';
      case 'failed':
        return '传输失败';
      case 'cancelled':
        return '已取消';
      default:
        return '未知状态';
    }
  }

  /// 根据 MIME 类型或状态获取图标
  static IconData getStatusIcon(String status, {String? mimeType}) {
    switch (status) {
      case 'completed':
        return Icons.check_circle;
      case 'failed':
        return Icons.error;
      case 'cancelled':
        return Icons.cancel;
      default:
        if (mimeType != null) {
          return FileUtils.getFileIcon(mimeType);
        }
        return Icons.insert_drive_file;
    }
  }
}
