import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 权限服务
class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// 请求蓝牙权限
  Future<bool> requestBluetoothPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,  // Android 12+ 广播需要
      Permission.location,
      Permission.locationWhenInUse,
    ];

    final results = <PermissionStatus>[];

    for (final permission in permissions) {
      final status = await permission.status;
      if (status.isDenied) {
        results.add(await permission.request());
      } else {
        results.add(status);
      }
    }

    return results.every((status) =>
        status.isGranted || status.isLimited);
  }

  /// 检查蓝牙权限
  Future<bool> hasBluetoothPermissions() async {
    final bluetooth = await Permission.bluetooth.status;
    final location = await Permission.locationWhenInUse.status;

    return bluetooth.isGranted && location.isGranted;
  }

  /// 请求存储权限
  Future<bool> requestStoragePermissions() async {
    final photos = await Permission.photos.status;
    if (photos.isDenied) {
      await Permission.photos.request();
    }

    final storage = await Permission.storage.status;
    if (storage.isDenied) {
      await Permission.storage.request();
    }

    return true;
  }

  /// 请求通知权限（用于后台传输通知）
  Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isDenied) {
      final result = await Permission.notification.request();
      return result.isGranted;
    }
    return true;
  }

  /// 打开应用设置
  Future<void> openSettings() async {
    await openAppSettings();
  }

  /// 获取缺失的权限列表
  Future<List<Permission>> getMissingPermissions() async {
    final missing = <Permission>[];

    if (!(await Permission.bluetooth.isGranted)) {
      missing.add(Permission.bluetooth);
    }
    if (!(await Permission.locationWhenInUse.isGranted)) {
      missing.add(Permission.locationWhenInUse);
    }
    if (!(await Permission.photos.isGranted)) {
      missing.add(Permission.photos);
    }

    return missing;
  }
}

/// 权限状态枚举
enum AppPermission {
  bluetooth,
  location,
  storage,
  notification,
  nfc,
}

/// 权限工具扩展
extension PermissionExtension on AppPermission {
  String get displayName {
    switch (this) {
      case AppPermission.bluetooth:
        return '蓝牙';
      case AppPermission.location:
        return '位置';
      case AppPermission.storage:
        return '存储';
      case AppPermission.notification:
        return '通知';
      case AppPermission.nfc:
        return 'NFC';
    }
  }

  String get description {
    switch (this) {
      case AppPermission.bluetooth:
        return '用于发现并连接附近设备';
      case AppPermission.location:
        return '蓝牙扫描需要位置权限（Android 系统要求）';
      case AppPermission.storage:
        return '用于访问和保存文件';
      case AppPermission.notification:
        return '用于显示传输进度通知';
      case AppPermission.nfc:
        return '用于 NFC 触碰快速连接';
    }
  }

  IconData get icon {
    switch (this) {
      case AppPermission.bluetooth:
        return Icons.bluetooth;
      case AppPermission.location:
        return Icons.location_on;
      case AppPermission.storage:
        return Icons.folder;
      case AppPermission.notification:
        return Icons.notifications;
      case AppPermission.nfc:
        return Icons.nfc;
    }
  }
}
