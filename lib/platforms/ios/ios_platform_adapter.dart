import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// iOS 平台适配器
class IosPlatformAdapter {
  static final IosPlatformAdapter _instance = IosPlatformAdapter._internal();
  factory IosPlatformAdapter() => _instance;
  IosPlatformAdapter._internal();

  /// 大文件阈值（超过此值建议使用 AirDrop）
  static const int largeFileThreshold = 50 * 1024 * 1024; // 50MB

  /// 检查是否为 iOS 平台
  bool get isIOS => Platform.isIOS;

  /// 检查蓝牙权限
  Future<bool> checkBluetoothPermission() async {
    if (!isIOS) return true;

    final bluetoothStatus = await Permission.bluetooth.status;
    final bluetoothScanStatus = await Permission.bluetoothScan.status;
    final bluetoothConnectStatus = await Permission.bluetoothConnect.status;

    return bluetoothStatus.isGranted &&
        bluetoothScanStatus.isGranted &&
        bluetoothConnectStatus.isGranted;
  }

  /// 请求蓝牙权限
  Future<bool> requestBluetoothPermission() async {
    if (!isIOS) return true;

    final bluetoothStatus = await Permission.bluetooth.request();
    final bluetoothScanStatus = await Permission.bluetoothScan.request();
    final bluetoothConnectStatus = await Permission.bluetoothConnect.request();

    return bluetoothStatus.isGranted &&
        bluetoothScanStatus.isGranted &&
        bluetoothConnectStatus.isGranted;
  }

  /// 检查位置权限（iOS BLE 扫描不需要，仅在使用 iBeacon 时需要）
  Future<bool> checkLocationPermission() async {
    if (!isIOS) return true;

    final status = await Permission.locationWhenInUse.status;
    return status.isGranted;
  }

  /// 请求位置权限
  Future<bool> requestLocationPermission() async {
    if (!isIOS) return true;

    final status = await Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  /// 监听蓝牙状态变化（iOS）
  Stream<BluetoothAdapterState> observeBluetoothState() {
    return FlutterBluePlus.adapterState;
  }

  /// 检查是否应该使用 AirDrop
  bool shouldUseAirDrop(int fileSize) {
    if (!isIOS) return false;
    return fileSize > largeFileThreshold;
  }

  /// 获取平台蓝牙说明
  String getPlatformNotes() {
    if (!isIOS) return '';

    return '''
iOS 蓝牙使用说明：

1. 蓝牙传输需要 App 在前台运行
2. 按 Home 键或切换 App 可能中断传输
3. 大文件（> 50MB）建议使用系统 AirDrop
4. 首次使用需要授权蓝牙权限

如需传输大文件，请点击右上角分享按钮使用 AirDrop。
''';
  }

  /// iOS 特有的传输限制提示
  String getTransferLimitationWarning(int fileSize) {
    if (!isIOS) return '';

    if (fileSize > largeFileThreshold) {
      return '文件较大（${_formatFileSize(fileSize)}），建议使用 AirDrop 分享以获得更快速度和更稳定的传输体验。';
    }
    return '';
  }

  /// 格式化文件大小
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// 获取 iOS 后台限制说明
  String getBackgroundLimitationNote() {
    if (!isIOS) return '';

    return '''
⚠️ iOS 限制说明

由于 iOS 系统的限制，蓝牙文件传输需要 App 保持前台运行：
- 请勿按 Home 键或切换到其他 App
- 保持屏幕唤醒或 App 在任务管理器中可见
- 如需后台传输，请使用系统 AirDrop 功能

感谢您的理解。
''';
  }
}
