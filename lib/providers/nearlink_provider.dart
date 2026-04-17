import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bluetooth/nearlink_bluetooth_service.dart';
import '../models/nearlink_models.dart';
import '../services/file_transfer_service.dart';
import '../platforms/android/nfc_dispatcher.dart';
import '../platforms/ios/ios_platform_adapter.dart';
import '../services/permission_service.dart';
import '../widgets/nearlink_widgets.dart';

/// 连接成功事件
class ConnectionSuccessEvent {
  final String deviceName;
  final String deviceId;
  final int signalStrength;
  final DeviceType deviceType;
  final bool isIncoming; // 是否是接收到的连接（被动连接）

  ConnectionSuccessEvent({
    required this.deviceName,
    required this.deviceId,
    required this.signalStrength,
    required this.deviceType,
    this.isIncoming = false,
  });
}

/// 传输完成事件
class TransferCompleteEvent {
  final String fileName;
  final int fileSize;
  final bool success;
  final String? errorMessage;

  TransferCompleteEvent({
    required this.fileName,
    required this.fileSize,
    required this.success,
    this.errorMessage,
  });
}

/// NearLink 应用状态管理
class NearLinkProvider extends ChangeNotifier {
  static final NearLinkProvider _instance = NearLinkProvider._internal();
  factory NearLinkProvider() => _instance;
  NearLinkProvider._internal();

  final NearLinkBluetoothService _bluetoothService = NearLinkBluetoothService();
  final FileTransferService _fileTransferService = FileTransferService();
  final PermissionService _permissionService = PermissionService();
  final IosPlatformAdapter _iosAdapter = IosPlatformAdapter();

  // Android NFC 调度器（仅 Android）
  NfcDispatcher? _nfcDispatcher;

  // SharedPreferences key
  static const String _darkModeKey = 'dark_mode';

  // 状态
  bool _isInitialized = false;
  bool _isInitializing = false; // 防止重复初始化
  bool _isDarkMode = false;
  String? _currentDeviceName;
  String? _selectedFilePath;
  Uint8List? _selectedFileBytes; // 用于存储从 image_picker 选择的文件字节
  String? _selectedFileName; // 存储文件名
  bool _compressImages = false; // 是否压缩图片

  // 连接成功的设备信息
  NearbyDevice? _connectedRemoteDevice;

  // 被动连接事件流
  final StreamController<ConnectionSuccessEvent> _incomingConnectionController =
      StreamController<ConnectionSuccessEvent>.broadcast();
  Stream<ConnectionSuccessEvent> get onIncomingConnection =>
      _incomingConnectionController.stream;

  // 文件接收事件流（作为接收方收到文件时通知UI）
  final StreamController<List<FileTransfer>> _transferReceivedController =
      StreamController<List<FileTransfer>>.broadcast();
  Stream<List<FileTransfer>> get onTransferReceived =>
      _transferReceivedController.stream;

  // 文件保存完成事件流
  final StreamController<String> _fileSavedController =
      StreamController<String>.broadcast();
  Stream<String> get onFileSaved => _fileSavedController.stream;

  // 存储最近一个被动连接的信息
  String? _lastIncomingDeviceName;
  String? _lastIncomingDeviceId;

  // 记录已经触发过接收文件界面跳转的 fileId，防止重复触发
  final Set<String> _notifiedReceiveFileIds = {};

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isDarkMode => _isDarkMode;
  bool get compressImages => _compressImages;
  NearLinkConnectionState get connectionState =>
      _bluetoothService.connectionState;
  List<NearbyDevice> get discoveredDevices =>
      _bluetoothService.discoveredDevices;
  BluetoothDevice? get connectedDevice => _bluetoothService.connectedDevice;
  bool get isConnected => _bluetoothService.isConnected;
  String? get errorMessage => _bluetoothService.errorMessage;
  String get deviceName => _currentDeviceName ?? 'NearLink';
  List<FileTransfer> get activeTransfers =>
      _fileTransferService.activeTransfers;
  String? get lastIncomingDeviceName => _lastIncomingDeviceName;

  /// 返回当前传输任务的副本，确保 Selector 能检测到内部属性变化
  FileTransfer? get currentTransfer {
    final transfer = _fileTransferService.currentTransfer;
    if (transfer == null) return null;
    // 返回一个新的实例，确保 Selector 的相等性检查能检测到变化
    return FileTransfer(
      fileId: transfer.fileId,
      fileName: transfer.fileName,
      filePath: transfer.filePath,
      fileSize: transfer.fileSize,
      mimeType: transfer.mimeType,
      totalChunks: transfer.totalChunks,
      currentChunk: transfer.currentChunk,
      progress: transfer.progress,
      status: transfer.status,
      startTime: transfer.startTime,
      errorMessage: transfer.errorMessage,
      isOutgoing: transfer.isOutgoing,
    );
  }

  bool get isIOS => _iosAdapter.isIOS;
  NearbyDevice? get connectedRemoteDevice => _connectedRemoteDevice;

  // 广播相关 Getters
  AdvertisingState get advertisingState => _bluetoothService.advertisingState;
  bool get isAdvertising => _bluetoothService.isAdvertising;
  DateTime? get advertiseStartTime => _bluetoothService.advertiseStartTime;
  int? get advertiseDuration => _bluetoothService.advertiseDuration;
  bool get isAdvertiseTimeout => _bluetoothService.isAdvertiseTimeout;

  // iOS 作为 Peripheral 被连接的 Getters
  bool get isPeripheralConnected => _bluetoothService.isPeripheralConnected;
  String? get connectedCentralId => _bluetoothService.connectedCentralId;

  /// 初始化
  Future<void> initialize() async {
    // 防止重复初始化或并发初始化
    if (_isInitialized || _isInitializing) return;
    _isInitializing = true;

    _currentDeviceName =
        'NearLink-${DateTime.now().millisecondsSinceEpoch % 10000}';

    // 加载保存的深色模式设置
    await _loadDarkModePreference();

    // 初始化蓝牙服务
    await _bluetoothService.initialize(deviceName: _currentDeviceName!);

    // 监听蓝牙服务状态变化
    _bluetoothService.addListener(_onBluetoothServiceChanged);

    // 初始化文件传输服务
    _fileTransferService.initialize();

    // 监听文件传输服务的变化（检测接收到的文件）
    _fileTransferService.addListener(_onFileTransferChanged);

    // 监听握手事件，用于检测被动连接
    _fileTransferService.onHandshakeReceived.listen((deviceName) {
      _onIncomingConnection(deviceName);
    });

    // 监听文件保存完成事件
    _fileTransferService.onFileSaved.listen((savePath) {
      _fileSavedController.add(savePath);
    });

    // Android: 初始化 NFC
    if (!_iosAdapter.isIOS) {
      _nfcDispatcher = NfcDispatcher();
      await _nfcDispatcher!.startListening(
        onTrigger: _onNfcTrigger,
      );
    }

    _isInitialized = true;
    _isInitializing = false;
    notifyListeners();
  }

  /// 检查并请求权限（在需要时调用，如点击扫描按钮）
  /// 返回 true 表示权限已获取，可以继续操作
  Future<bool> checkAndRequestPermissions(BuildContext context) async {
    // 先检查蓝牙是否开启
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      if (context.mounted) {
        _showBluetoothOffDialog(context);
      }
      return false;
    }

    final hasPermissions = await _permissionService.hasBluetoothPermissions();
    if (hasPermissions) {
      return true;
    }

    // 检查是否被永久拒绝
    final isPermanentlyDenied =
        await _permissionService.isBluetoothPermissionPermanentlyDenied();
    if (isPermanentlyDenied && context.mounted) {
      // 权限被永久拒绝，直接引导去设置
      _showPermissionDeniedDialog(context);
      return false;
    }

    if (!context.mounted) {
      return false;
    }

    // 显示权限说明对话框
    final shouldRequest = await _showPermissionExplanationDialog(context);
    if (!shouldRequest) {
      return false;
    }

    // 请求权限
    final granted = await _permissionService.requestBluetoothPermissions();
    if (!context.mounted) {
      return granted;
    }
    if (!granted && context.mounted) {
      // 权限被拒绝，提示用户
      _showPermissionDeniedDialog(context);
    }
    return granted;
  }

  /// 显示蓝牙未开启对话框
  void _showBluetoothOffDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: NearLinkColors.error),
            SizedBox(width: 8),
            Text('蓝牙未开启'),
          ],
        ),
        content: const Text('请在系统设置中开启蓝牙后重试。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 显示权限说明对话框
  Future<bool> _showPermissionExplanationDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth, color: NearLinkColors.primary),
            SizedBox(width: 8),
            Text('需要蓝牙权限'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('NearLink 需要以下权限来发现和连接附近设备：'),
            const SizedBox(height: 12),
            const _PermissionItem(icon: Icons.bluetooth, text: '蓝牙扫描和连接'),
            if (Platform.isAndroid)
              const _PermissionItem(
                  icon: Icons.location_on, text: '位置信息（系统要求用于蓝牙扫描）'),
            const SizedBox(height: 12),
            const Text(
              '所有数据传输仅在设备间直接进行，不会上传至服务器。',
              style:
                  TextStyle(fontSize: 12, color: NearLinkColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: NearLinkColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('授权'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 显示权限被拒绝对话框
  void _showPermissionDeniedDialog(BuildContext context) {
    final isIOS = Platform.isIOS;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: NearLinkColors.error),
            SizedBox(width: 8),
            Text('蓝牙权限被拒绝'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NearLink 需要蓝牙权限来发现和连接附近设备。',
            ),
            const SizedBox(height: 12),
            if (isIOS) ...[
              const Text(
                '请在设置中开启权限：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text('设置 > 隐私与安全性 > 蓝牙 > NearLink'),
            ] else ...[
              const Text(
                '请在设置中开启蓝牙和位置权限',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _permissionService.openSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('去设置'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NearLinkColors.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  /// 蓝牙服务状态变化回调
  void _onBluetoothServiceChanged() {
    if (!_bluetoothService.isConnected &&
        !_bluetoothService.isPeripheralConnected) {
      _connectedRemoteDevice = null;
    }

    // 检测 iOS 作为 Peripheral 被连接的状态变化
    if (_bluetoothService.isPeripheralConnected &&
        _lastIncomingDeviceName == null) {
      // iOS 被连接，触发被动连接事件
      _lastIncomingDeviceName = 'Android 设备';
      _lastIncomingDeviceId = _bluetoothService.connectedCentralId;
      _incomingConnectionController.add(ConnectionSuccessEvent(
        deviceName: 'Android 设备',
        deviceId: _bluetoothService.connectedCentralId ?? '',
        signalStrength: -50,
        deviceType: DeviceType.phone,
        isIncoming: true,
      ));
    } else if (!_bluetoothService.isPeripheralConnected &&
        _lastIncomingDeviceName != null) {
      // iOS 断开连接，清除状态
      _lastIncomingDeviceName = null;
      _lastIncomingDeviceId = null;

      // 取消正在进行的文件传输
      _cancelActiveTransfers();
    }

    notifyListeners();
  }

  /// 取消所有活跃的文件传输
  void _cancelActiveTransfers() {
    final activeTransfers = _fileTransferService.activeTransfers;
    for (final transfer in activeTransfers) {
      if (transfer.status == TransferStatus.transferring) {
        _fileTransferService.cancelTransfer(transfer.fileId);
      }
    }
  }

  /// 文件传输服务状态变化回调
  void _onFileTransferChanged() {
    final activeTransfers = _fileTransferService.activeTransfers;

    // 1. 通知 UI 更新进度（每次状态变化都需要）
    notifyListeners();

    // 2. 检查是否有新的接收中的传输，只在首次检测到时触发界面跳转
    if (activeTransfers.isNotEmpty) {
      final receivingTransfers = activeTransfers
          .where(
              (t) => !t.isOutgoing && t.status == TransferStatus.transferring)
          .toList();

      for (final transfer in receivingTransfers) {
        // 只在尚未通知过的传输上触发界面跳转
        if (!_notifiedReceiveFileIds.contains(transfer.fileId)) {
          _notifiedReceiveFileIds.add(transfer.fileId);
          _transferReceivedController.add([transfer]);
          break; // 一次只处理一个新的接收传输
        }
      }
    }

    // 3. 清理已完成或取消的传输的记录
    final activeFileIds = activeTransfers.map((t) => t.fileId).toSet();
    _notifiedReceiveFileIds.removeWhere((id) => !activeFileIds.contains(id));
  }

  /// 处理被动连接（收到握手请求）
  void _onIncomingConnection(String deviceName) {
    // 防重复触发：如果已经通知过任何设备（通过 centralConnected 或之前的握手），
    // 就不再触发新的连接提示
    if (_lastIncomingDeviceName != null) {
      // 更新设备名称（如果握手提供了更准确的名称）
      if (_lastIncomingDeviceName == 'Android 设备' ||
          _lastIncomingDeviceName == 'iOS 设备') {
        _lastIncomingDeviceName = deviceName;
      }
      return;
    }

    _lastIncomingDeviceName = deviceName;

    // 通知 UI 显示连接成功提示
    _incomingConnectionController.add(ConnectionSuccessEvent(
      deviceName: deviceName,
      deviceId: _lastIncomingDeviceId ?? '',
      signalStrength: -50, // 默认值
      deviceType: DeviceType.phone,
      isIncoming: true,
    ));
  }

  /// 加载深色模式设置
  Future<void> _loadDarkModePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDarkMode = prefs.getBool(_darkModeKey) ?? false;
    } catch (e) {
      _isDarkMode = false;
    }
  }

  /// 保存深色模式设置
  Future<void> _saveDarkModePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_darkModeKey, _isDarkMode);
    } catch (e) {
      // 忽略保存错误
    }
  }

  /// NFC 触发回调
  void _onNfcTrigger(String? deviceId) {
    notifyListeners();
  }

  /// 开始扫描
  Future<void> startScan() async {
    await _bluetoothService.startScan();
    notifyListeners();
  }

  /// 停止扫描
  Future<void> stopScan() async {
    await _bluetoothService.stopScan();
    notifyListeners();
  }

  /// ==========================================
  /// 独立的广播控制方法
  /// ==========================================

  /// 开始广播
  Future<bool> startAdvertising({int? timeoutSeconds}) async {
    final success = await _bluetoothService.startAdvertising(
      timeoutSeconds: timeoutSeconds,
    );
    notifyListeners();
    return success;
  }

  /// 停止广播
  Future<void> stopAdvertising() async {
    await _bluetoothService.stopAdvertising();
    notifyListeners();
  }

  /// 重置广播（超时后使用）
  Future<void> resetAdvertising() async {
    await _bluetoothService.resetAdvertising();
    notifyListeners();
  }

  /// 切换广播状态（开启/关闭）
  Future<void> toggleAdvertising({int? timeoutSeconds}) async {
    if (isAdvertising) {
      await stopAdvertising();
    } else {
      await startAdvertising(timeoutSeconds: timeoutSeconds);
    }
  }

  /// 连接到设备
  Future<bool> connectToDevice(NearbyDevice device) async {
    _updateConnectionState(NearLinkConnectionState.connecting);
    notifyListeners();

    final success = await _bluetoothService.connectToDevice(device);

    if (success) {
      // 保存连接的设备信息
      _connectedRemoteDevice = device;
      await _bluetoothService.sendHandshake();
      _updateConnectionState(NearLinkConnectionState.connected);
    } else {
      _updateConnectionState(NearLinkConnectionState.disconnected);
    }

    notifyListeners();
    return success;
  }

  /// 断开连接
  Future<void> disconnect() async {
    _connectedRemoteDevice = null;
    await _bluetoothService.disconnect();
    notifyListeners();
  }

  /// 选择文件
  void selectFile(String path) {
    _selectedFilePath = path;
    notifyListeners();
  }

  /// 清除选中的文件
  void clearSelectedFile() {
    _selectedFilePath = null;
    _selectedFileBytes = null;
    _selectedFileName = null;
    notifyListeners();
  }

  /// 选择文件（从 image_picker 传入字节数据）
  void selectFileWithBytes(String fileName, Uint8List bytes) {
    _selectedFileName = fileName;
    _selectedFileBytes = bytes;
    _selectedFilePath = null; // 使用字节数据，不使用路径
    notifyListeners();
  }

  /// 检查是否有选中的文件（路径或字节）
  bool get hasSelectedFile =>
      _selectedFilePath != null || _selectedFileBytes != null;

  /// 获取选中的文件名
  String? get selectedFileName => _selectedFilePath != null
      ? _selectedFilePath!.split('/').last
      : _selectedFileName;

  /// 获取选中的文件字节数据
  Uint8List? get selectedFileBytes => _selectedFileBytes;

  /// 准备并发送文件
  Future<FileTransfer?> sendFile({bool? compressImage}) async {
    // 如果未指定压缩选项，使用用户设置
    final shouldCompress = compressImage ?? _compressImages;

    FileTransfer? transfer;

    if (_selectedFileBytes != null && _selectedFileName != null) {
      // 使用 image_picker 传入的字节数据
      transfer = await _fileTransferService.prepareFileWithBytes(
        _selectedFileName!,
        _selectedFileBytes!,
        compressImage: shouldCompress,
      );
    } else if (_selectedFilePath != null) {
      // 使用文件路径
      transfer = await _fileTransferService.prepareFile(
        _selectedFilePath!,
        compressImage: shouldCompress,
      );
    } else {
      return null;
    }

    if (transfer != null) {
      clearSelectedFile();
      await _fileTransferService.startSend(transfer.fileId);
    }
    notifyListeners();
    return transfer;
  }

  /// 设置是否压缩图片
  void setCompressImages(bool value) {
    _compressImages = value;
    notifyListeners();
  }

  /// 取消传输
  Future<void> cancelTransfer(String fileId) async {
    await _fileTransferService.cancelTransfer(fileId);
    notifyListeners();
  }

  /// 切换深色模式
  Future<void> toggleDarkMode() async {
    _isDarkMode = !_isDarkMode;
    await _saveDarkModePreference();
    notifyListeners();
  }

  /// 获取 iOS 传输建议
  String getIosTransferAdvice(int fileSize) {
    return _iosAdapter.getTransferLimitationWarning(fileSize);
  }

  /// 获取 iOS 后台限制说明
  String getBackgroundLimitationNote() {
    return _iosAdapter.getBackgroundLimitationNote();
  }

  /// 清除错误
  void clearError() {
    _bluetoothService.clearError();
    notifyListeners();
  }

  void _updateConnectionState(NearLinkConnectionState state) {
    // 内部状态更新，不触发外部通知
  }

  @override
  void dispose() {
    _bluetoothService.removeListener(_onBluetoothServiceChanged);
    _nfcDispatcher?.dispose();
    super.dispose();
  }
}

/// 权限项组件（用于权限说明对话框）
class _PermissionItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PermissionItem({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF2196F3)),
          const SizedBox(width: 8),
          Text(text),
        ],
      ),
    );
  }
}
