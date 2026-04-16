import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 权限服务
class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// 请求蓝牙权限
  Future<bool> requestBluetoothPermissions() async {
    // iOS：使用蓝牙会触发系统权限弹窗，不需要手动请求
    // 只需要检查状态是否是 unauthorized
    if (Platform.isIOS) {
      final adapterState = await FlutterBluePlus.adapterState.first;
      // unauthorized 表示权限被拒绝，其他状态都表示有权限（系统已授权或不需要授权）
      return adapterState != BluetoothAdapterState.unauthorized;
    }

    // Android 使用细分的蓝牙权限
    final permissions = <Permission>[];

    final scanStatus = await Permission.bluetoothScan.status;
    final connectStatus = await Permission.bluetoothConnect.status;
    final advertiseStatus = await Permission.bluetoothAdvertise.status;

    if (scanStatus.isDenied) {
      permissions.add(Permission.bluetoothScan);
    }
    if (connectStatus.isDenied) {
      permissions.add(Permission.bluetoothConnect);
    }
    if (advertiseStatus.isDenied) {
      permissions.add(Permission.bluetoothAdvertise);
    }

    // 位置权限（Android 需要）
    if (await Permission.locationWhenInUse.status.isDenied) {
      permissions.add(Permission.locationWhenInUse);
    }

    if (permissions.isEmpty) {
      return true;
    }

    final results = await permissions.request();

    return results.values
        .every((status) => status.isGranted || status.isLimited);
  }

  /// 检查蓝牙权限
  Future<bool> hasBluetoothPermissions() async {
    // iOS 使用 flutter_blue_plus 的蓝牙状态来检查权限
    if (Platform.isIOS) {
      final adapterState = await FlutterBluePlus.adapterState.first;
      // unauthorized 表示没有权限，其他状态（on/off）都表示有权限
      return adapterState != BluetoothAdapterState.unauthorized;
    }

    // Android 使用细分的蓝牙权限
    final bluetoothScan = await Permission.bluetoothScan.status;
    final bluetoothConnect = await Permission.bluetoothConnect.status;
    final location = await Permission.locationWhenInUse.status;

    return bluetoothScan.isGranted &&
        bluetoothConnect.isGranted &&
        location.isGranted;
  }

  /// 检查权限是否被永久拒绝
  Future<bool> isBluetoothPermissionPermanentlyDenied() async {
    if (Platform.isIOS) {
      // iOS 上使用蓝牙会触发权限弹窗，如果用户拒绝则状态是 unauthorized
      final adapterState = await FlutterBluePlus.adapterState.first;
      return adapterState == BluetoothAdapterState.unauthorized;
    }

    final bluetoothScan = await Permission.bluetoothScan.status;
    final bluetoothConnect = await Permission.bluetoothConnect.status;
    return bluetoothScan.isPermanentlyDenied ||
        bluetoothConnect.isPermanentlyDenied;
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
        return '蓝牙扫描需要位置权限（仅 Android 系统要求）';
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
