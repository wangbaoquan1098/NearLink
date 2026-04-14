import 'dart:async';
import 'dart:typed_data';
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
  NearLinkConnectionState get connectionState => _bluetoothService.connectionState;
  List<NearbyDevice> get discoveredDevices => _bluetoothService.discoveredDevices;
  BluetoothDevice? get connectedDevice => _bluetoothService.connectedDevice;
  bool get isConnected => _bluetoothService.isConnected;
  String? get errorMessage => _bluetoothService.errorMessage;
  String get deviceName => _currentDeviceName ?? 'NearLink';
  List<FileTransfer> get activeTransfers => _fileTransferService.activeTransfers;
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
    if (_isInitialized) return;

    _currentDeviceName = 'NearLink-${DateTime.now().millisecondsSinceEpoch % 10000}';

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

    // 请求必要权限
    await _permissionService.requestBluetoothPermissions();

    _isInitialized = true;
    notifyListeners();
  }

  /// 蓝牙服务状态变化回调
  void _onBluetoothServiceChanged() {
    // 检测 iOS 作为 Peripheral 被连接的状态变化
    if (_bluetoothService.isPeripheralConnected && _lastIncomingDeviceName == null) {
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
    } else if (!_bluetoothService.isPeripheralConnected && _lastIncomingDeviceName != null) {
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
      final receivingTransfers = activeTransfers.where(
        (t) => !t.isOutgoing && t.status == TransferStatus.transferring
      ).toList();
      
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
      if (_lastIncomingDeviceName == 'Android 设备' || _lastIncomingDeviceName == 'iOS 设备') {
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
  bool get hasSelectedFile => _selectedFilePath != null || _selectedFileBytes != null;

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
