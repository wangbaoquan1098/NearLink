import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/nearlink_models.dart';

/// 广播超时异常
class AdvertiseTimeoutException implements Exception {
  final String message;
  AdvertiseTimeoutException(this.message);
  @override
  String toString() => 'AdvertiseTimeoutException: $message';
}

/// 自定义超时异常
class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => 'TimeoutException: $message';
}

/// NearLink 蓝牙服务 UUID
class NearLinkConstants {
  static const String serviceUuid = "0000FFFF-0000-1000-8000-00805F9B34FB";
  static const String charTxUuid = "0000FF01-0000-1000-8000-00805F9B34FB";
  static const String charRxUuid = "0000FF02-0000-1000-8000-00805F9B34FB";
  static const String charNotifyUuid = "0000FF03-0000-1000-8000-00805F9B34FB";

  static const int maxChunkSize =
      440; // BLE MTU 限制 (512 - 3 - 64 = 445, 留一些余量用 440)
  static const int scanTimeout = 30; // 扫描超时（秒）
  static const int connectionTimeout = 10; // 连接超时（秒）
  static const int handshakeTimeout = 5; // 握手超时（秒）
  static const int advertiseTimeout = 300; // 广播超时（5分钟）
  static const int headerSize = 64; // 数据包头部长度
  static const int heartbeatInterval = 2; // 心跳间隔（秒）
  static const int peerTimeout = 6; // 对端超时判定（秒）
}

/// 广播状态
enum AdvertisingState {
  stopped, // 已停止
  starting, // 正在启动
  advertising, // 广播中
  error, // 错误
}

/// 蓝牙连接和传输服务
class NearLinkBluetoothService extends ChangeNotifier {
  static final NearLinkBluetoothService _instance =
      NearLinkBluetoothService._internal();
  factory NearLinkBluetoothService() => _instance;
  NearLinkBluetoothService._internal();

  final Uuid _uuid = const Uuid();
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _rxSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  NearLinkConnectionState _connectionState =
      NearLinkConnectionState.disconnected;
  final List<NearbyDevice> _discoveredDevices = [];
  String? _errorMessage;
  String _deviceName = '';
  String _deviceId = '';

  // 广播相关
  AdvertisingState _advertisingState = AdvertisingState.stopped;
  Timer? _advertiseTimeoutTimer;
  DateTime? _advertiseStartTime;

  // Android 广播通道
  static const MethodChannel _androidChannel =
      MethodChannel('com.nearlink/ble_advertise');

  // iOS Event Channel（监听作为 Peripheral 时的连接事件）
  static const EventChannel _iosEventChannel =
      EventChannel('com.nearlink/ble_advertise_events');
  StreamSubscription<dynamic>? _iosEventSubscription;

  // 作为 Peripheral 被连接的状态（iOS 广播时被连接）
  bool _isPeripheralConnected = false;
  String? _connectedCentralId;
  String? _connectedCentralName;
  int? _connectedCentralMtu;
  bool _connectedDeviceIsIOSPeer = false;
  static const Duration _androidPeripheralQueueDrainTimeout =
      Duration(minutes: 3);
  static const Duration _androidPeripheralQueuePollInterval =
      Duration(milliseconds: 200);

  // 数据包缓冲（用于处理粘包问题）
  final List<int> _packetBuffer = [];
  Timer? _heartbeatTimer;
  DateTime? _lastPeerActivityAt;
  bool _heartbeatInFlight = false;

  // Getters

  // Getters
  NearLinkConnectionState get connectionState => _connectionState;

  /// 是否作为 Peripheral 被连接（iOS 广播模式）
  bool get isPeripheralConnected => _isPeripheralConnected;

  /// 已连接的中心设备信息
  String? get connectedCentralId => _connectedCentralId;
  String? get connectedCentralName => _connectedCentralName;
  int? get connectedCentralMtu => _connectedCentralMtu;
  bool get isConnectedToIOSPeer => _connectedDeviceIsIOSPeer;
  List<NearbyDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);
  BluetoothDevice? get connectedDevice => _connectedDevice;
  String? get errorMessage => _errorMessage;
  String get deviceName => _deviceName;
  bool get isConnected => _connectionState == NearLinkConnectionState.connected;

  // 广播 Getters
  AdvertisingState get advertisingState => _advertisingState;
  bool get isAdvertising => _advertisingState == AdvertisingState.advertising;
  DateTime? get advertiseStartTime => _advertiseStartTime;

  /// 获取广播持续时间（秒）
  int? get advertiseDuration {
    if (_advertiseStartTime == null) return null;
    return DateTime.now().difference(_advertiseStartTime!).inSeconds;
  }

  /// 初始化服务
  Future<void> initialize({required String deviceName}) async {
    _deviceName = deviceName;
    _deviceId = _uuid.v4();

    // 监听蓝牙状态变化（不立即获取状态，避免 iOS 启动时弹窗）
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.off) {
        _stopHeartbeatMonitoring();
        _updateConnectionState(NearLinkConnectionState.disconnected);
        _errorMessage = '蓝牙已关闭';
        notifyListeners();
      } else if (state == BluetoothAdapterState.on) {
        _errorMessage = null;
        notifyListeners();
      }
    });

    // 监听作为 Peripheral 的连接事件（iOS 和 Android 都支持）
    _setupIOSPeripheralListener();
  }

  /// 设置 Peripheral 连接事件监听（iOS 和 Android 都使用）
  void _setupIOSPeripheralListener() {
    _iosEventSubscription?.cancel();
    _iosEventSubscription = _iosEventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final eventType = event['event'] as String?;

          switch (eventType) {
            case 'advertisingStarted':
              _advertisingState = AdvertisingState.advertising;
              _advertiseStartTime = DateTime.now();
              _errorMessage = null;
              notifyListeners();
              break;

            case 'advertisingStopped':
              _advertisingState = AdvertisingState.stopped;
              _advertiseStartTime = null;
              notifyListeners();
              break;

            case 'centralConnected':
              // 有中心设备连接（对方连接到了本机 Peripheral）
              _isPeripheralConnected = true;
              _connectedCentralId = event['centralId'] as String?;
              _connectedCentralMtu = event['mtu'] as int?;
              // 停止广播
              stopAdvertising();
              _errorMessage = null;
              _startHeartbeatMonitoring();
              notifyListeners();
              break;

            case 'centralDisconnected':
              // 中心设备断开
              _isPeripheralConnected = false;
              _connectedCentralId = null;
              _connectedCentralName = null;
              _connectedCentralMtu = null;
              // 清理数据包缓冲区，避免影响下次传输
              _packetBuffer.clear();
              _stopHeartbeatMonitoring();
              notifyListeners();
              break;

            case 'dataReceived':
              final centralId = event['centralId'] as String?;

              // 某些设备上可能先收到写入数据，再收到/丢失订阅事件，这里做连接状态兜底。
              if (!_isPeripheralConnected) {
                _isPeripheralConnected = true;
                _connectedCentralId = centralId ?? _connectedCentralId;
                _connectedCentralMtu =
                    (event['mtu'] as int?) ?? _connectedCentralMtu;
                _errorMessage = null;
                stopAdvertising();
                _startHeartbeatMonitoring();
                notifyListeners();
              }

              // 作为 Peripheral 收到数据（来自对方的写入）
              final dynamic rawData = event['data'];

              Uint8List? data;
              if (rawData == null) {
                data = null;
              } else if (rawData is Uint8List) {
                data = rawData;
              } else if (rawData is List) {
                try {
                  data = Uint8List.fromList(rawData.cast<int>());
                } catch (e) {
                  data = null;
                }
              } else {
                // 尝试强制转换
                try {
                  data = Uint8List.fromList((rawData as List).cast<int>());
                } catch (e) {
                  data = null;
                }
              }

              if (data != null && data.isNotEmpty) {
                // 转发给数据包监听器处理
                _onDataReceived(data);
              }
              break;
          }
        }
      },
    );
  }

  /// 开始扫描设备（仅扫描，不自动广播）
  Future<void> startScan() async {
    if (_connectionState == NearLinkConnectionState.scanning) return;

    _discoveredDevices.clear();
    _updateConnectionState(NearLinkConnectionState.scanning);
    _errorMessage = null;
    notifyListeners();

    try {
      // 先取消之前的订阅
      _scanSubscription?.cancel();

      // 立即开始监听扫描结果
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          _handleScanResult(result);
        }
      });

      // 启动扫描
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: NearLinkConstants.scanTimeout),
        androidUsesFineLocation: true,
      );

      // 等待扫描结束
      await FlutterBluePlus.isScanning.firstWhere((scanning) => !scanning);

      _updateConnectionState(NearLinkConnectionState.disconnected);
    } catch (e) {
      _errorMessage = '扫描失败: $e';
      _updateConnectionState(NearLinkConnectionState.disconnected);
    }
    notifyListeners();
  }

  /// 处理扫描结果
  void _handleScanResult(ScanResult result) {
    final device = result.device;
    final advData = result.advertisementData;

    // 尝试从 Manufacturer Data 提取 NearLink 设备名称 (Android 广播方式)
    final androidAdvertiserName =
        _extractNearLinkNameFromManufacturerData(advData);
    String? nearLinkName = androidAdvertiserName;

    // 如果 Manufacturer Data 方式失败，尝试从服务 UUID 和本地名称识别 (iOS 广播方式)
    nearLinkName ??= _extractNearLinkNameFromServiceData(advData);

    // 如果不是 NearLink 设备，直接忽略
    if (nearLinkName == null) {
      return;
    }

    final isAndroidAdvertiser = androidAdvertiserName != null;

    final nearbyDevice = NearbyDevice(
      id: device.remoteId.str,
      name: nearLinkName,
      rssi: result.rssi,
      lastSeen: DateTime.now(),
      manufacturer: isAndroidAdvertiser ? 'android' : 'ios',
    );

    // 先按设备 ID 匹配；如果平台重启后地址变化，再按“平台 + 名称”做近似去重。
    final existingIndex = _findExistingDeviceIndex(nearbyDevice);
    final bool isNewDevice = existingIndex < 0;

    if (isNewDevice) {
      _discoveredDevices.add(nearbyDevice);
      notifyListeners();
    } else {
      _discoveredDevices[existingIndex] = nearbyDevice;
      notifyListeners();

      // 同一台 NearLink 设备第二次命中时，认为结果已经稳定，提前结束扫描。
      unawaited(stopScan());
    }
  }

  int _findExistingDeviceIndex(NearbyDevice device) {
    final exactIndex = _discoveredDevices.indexWhere((d) => d.id == device.id);
    if (exactIndex >= 0) return exactIndex;

    return _discoveredDevices.indexWhere((d) {
      final sameName = d.name == device.name;
      final sameManufacturer = d.manufacturer == device.manufacturer;
      return sameName && sameManufacturer;
    });
  }

  /// 从 Manufacturer Data 中提取 NearLink 设备名称 (Android 广播方式)
  /// 返回 null 表示不是 NearLink 设备
  String? _extractNearLinkNameFromManufacturerData(AdvertisementData advData) {
    try {
      final manufacturerData = advData.manufacturerData;

      if (manufacturerData.isEmpty) {
        return null;
      }

      // 查找 NearLink 厂商 ID (0xFF01)
      const nearLinkManufacturerId = 0xFF01;
      final data = manufacturerData[nearLinkManufacturerId];

      if (data == null || data.length < 5) {
        return null;
      }

      // 检查魔数: N E A R
      if (data[0] != 0x4E ||
          data[1] != 0x45 ||
          data[2] != 0x41 ||
          data[3] != 0x52) {
        return null;
      }

      // 获取名称长度
      final nameLength = data[4];
      if (data.length < 5 + nameLength) {
        return null;
      }

      // 提取名称
      final nameBytes = data.sublist(5, 5 + nameLength);
      return utf8.decode(nameBytes);
    } catch (e) {
      return null;
    }
  }

  /// 从 Service UUID 和本地名称识别 NearLink 设备 (iOS 广播方式)
  String? _extractNearLinkNameFromServiceData(AdvertisementData advData) {
    try {
      // 检查是否包含 NearLink 服务 UUID
      final serviceUuids = advData.serviceUuids;
      final hasNearLinkService = serviceUuids.any((uuid) =>
          uuid.str.toUpperCase().contains('FFFF') ||
          uuid.str.toUpperCase() ==
              NearLinkConstants.serviceUuid.toUpperCase());

      if (!hasNearLinkService) {
        return null;
      }

      // 使用本地名称作为设备名称
      final localName = advData.advName;
      if (localName.isNotEmpty) {
        return localName;
      }

      // 如果本地名称为空，检查是否包含 NearLink 特征的服务 UUID
      return "NearLink-Device";
    } catch (e) {
      return null;
    }
  }

  /// 开始广播（Android/iOS 跨平台）
  Future<bool> _startNativeAdvertising() async {
    try {
      if (Platform.isAndroid) {
        // Android 使用原生广播
        final result = await _androidChannel.invokeMethod('startAdvertising', {
          'deviceName': _deviceName,
          'serviceUuid': NearLinkConstants.serviceUuid,
        });
        if (result == true) {
          return true;
        } else {
          return false;
        }
      } else if (Platform.isIOS) {
        // iOS 使用原生广播
        final result = await _androidChannel.invokeMethod('startAdvertising', {
          'deviceName': _deviceName,
          'serviceUuid': NearLinkConstants.serviceUuid,
        });
        if (result == true) {
          return true;
        } else {
          // 广播失败不阻断扫描流程
          return true;
        }
      }
      return true;
    } on PlatformException {
      // 广播失败不阻断扫描流程
      return true;
    } on MissingPluginException {
      // 插件未实现不阻断扫描流程
      return true;
    } catch (e) {
      return true;
    }
  }

  /// 停止广播（私有）
  Future<void> _stopNativeAdvertising() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await _androidChannel.invokeMethod('stopAdvertising');
      }
    } catch (e) {
      // 停止失败
    }
  }

  /// ==========================================
  /// 独立的广播控制方法（供 UI 调用）
  /// ==========================================

  /// 开始广播（独立控制）
  Future<bool> startAdvertising({int? timeoutSeconds}) async {
    if (_advertisingState == AdvertisingState.advertising ||
        _advertisingState == AdvertisingState.starting) {
      return true;
    }

    _advertisingState = AdvertisingState.starting;
    _errorMessage = null;
    notifyListeners();

    try {
      final success = await _startNativeAdvertising();

      if (success) {
        _advertisingState = AdvertisingState.advertising;
        _advertiseStartTime = DateTime.now();

        // 设置超时定时器
        final timeout = timeoutSeconds ?? NearLinkConstants.advertiseTimeout;
        _advertiseTimeoutTimer?.cancel();
        _advertiseTimeoutTimer = Timer(Duration(seconds: timeout), () {
          stopAdvertising();
        });
      } else {
        _advertisingState = AdvertisingState.error;
        _errorMessage = '广播启动失败';
      }
    } catch (e) {
      _advertisingState = AdvertisingState.error;
      _errorMessage = '广播异常: $e';
    }

    notifyListeners();
    return _advertisingState == AdvertisingState.advertising;
  }

  /// 停止广播（独立控制）
  Future<void> stopAdvertising() async {
    if (_advertisingState == AdvertisingState.stopped) return;

    // 取消超时定时器
    _advertiseTimeoutTimer?.cancel();
    _advertiseTimeoutTimer = null;

    // 停止原生广播
    await _stopNativeAdvertising();

    _advertisingState = AdvertisingState.stopped;
    _advertiseStartTime = null;

    notifyListeners();
  }

  /// 重置广播状态（超时后调用）
  Future<void> resetAdvertising() async {
    await stopAdvertising();

    // 短暂延迟后自动重新开始广播
    await Future.delayed(const Duration(milliseconds: 500));
  }

  /// 检查广播是否超时
  bool get isAdvertiseTimeout {
    if (_advertiseStartTime == null) return false;
    final duration = DateTime.now().difference(_advertiseStartTime!).inSeconds;
    return duration >= NearLinkConstants.advertiseTimeout;
  }

  /// 重置广播超时定时器（连接成功后调用）
  void _resetAdvertiseTimeout() {
    if (_advertisingState != AdvertisingState.advertising) return;

    _advertiseTimeoutTimer?.cancel();
    _advertiseStartTime = DateTime.now();

    _advertiseTimeoutTimer = Timer(
      const Duration(seconds: NearLinkConstants.advertiseTimeout),
      () {
        stopAdvertising();
      },
    );
  }

  /// 停止扫描（不影响独立广播）
  Future<void> stopScan() async {
    _scanSubscription?.cancel();
    _scanSubscription = null;

    if (await FlutterBluePlus.isScanning.first) {
      await FlutterBluePlus.stopScan();
    }

    _updateConnectionState(NearLinkConnectionState.disconnected);
    notifyListeners();
  }

  /// 连接到设备
  Future<bool> connectToDevice(NearbyDevice device) async {
    _updateConnectionState(NearLinkConnectionState.connecting);
    _errorMessage = null;
    _connectedDeviceIsIOSPeer =
        (device.manufacturer ?? '').toLowerCase() == 'ios';
    _packetBuffer.clear();
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    notifyListeners();

    try {
      // 先停止扫描，避免干扰连接
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
      }

      // 等待一小段时间确保广播停止
      await Future.delayed(const Duration(milliseconds: 500));

      // 查找设备
      BluetoothDevice? targetDevice;

      if (!Platform.isIOS) {
        // Android 侧优先复用当前扫描结果里的实例
        try {
          final results = await FlutterBluePlus.scanResults.first.timeout(
            const Duration(seconds: 2),
            onTimeout: () => [],
          );
          targetDevice = results
              .firstWhere((r) => r.device.remoteId.str == device.id)
              .device;
        } catch (e) {
          // 扫描结果中未找到设备
        }
      }

      // iOS 重连时强制创建新实例，避免复用旧 peripheral 对象导致超时。
      targetDevice ??= BluetoothDevice(remoteId: DeviceIdentifier(device.id));

      try {
        await targetDevice.disconnect();
      } catch (_) {
        // 忽略预清理失败
      }

      // 增加 MTU 协商，这对跨平台连接很重要
      await targetDevice
          .connect(
        timeout: const Duration(seconds: NearLinkConstants.connectionTimeout),
        autoConnect: false,
      )
          .timeout(
        const Duration(seconds: NearLinkConstants.connectionTimeout + 5),
        onTimeout: () {
          throw TimeoutException('连接超时');
        },
      );

      // 等待连接状态确认（iOS需要更稳定的等待）
      BluetoothConnectionState? connectionState;
      try {
        await for (final state in targetDevice.connectionState) {
          connectionState = state;
          if (state == BluetoothConnectionState.connected) {
            break;
          }
          if (state == BluetoothConnectionState.disconnected) {
            break;
          }
        }
      } catch (e) {
        // 超时或其他错误
      }

      if (connectionState != BluetoothConnectionState.connected) {
        throw Exception('连接失败：设备已断开');
      }

      // 连接成功后请求更大的 MTU（Android 支持 517，iOS 支持 185）
      try {
        await targetDevice.requestMtu(517);
      } catch (e) {
        // MTU 协商失败
      }

      _connectedDevice = targetDevice;
      _discoveredDevices.clear();
      _updateConnectionState(NearLinkConnectionState.connected);
      _startHeartbeatMonitoring();
      notifyListeners();

      // 给 iOS 设备一些时间准备 GATT 服务
      await Future.delayed(const Duration(seconds: 1));

      // 发现服务 - 添加重试机制
      bool servicesDiscovered = false;
      for (int i = 0; i < 5; i++) {
        try {
          await _discoverServices();
          servicesDiscovered = true;
          break;
        } catch (e) {
          // 增加重试间隔
          await Future.delayed(Duration(milliseconds: 500 + i * 500));
        }
      }

      if (!servicesDiscovered) {
        throw Exception('无法发现 GATT 服务');
      }

      // 连接成功，重置广播超时以维持广播
      _resetAdvertiseTimeout();

      // 添加连接状态监听，以便在连接断开时及时检测
      _startConnectionStateListener();

      return true;
    } on TimeoutException {
      _errorMessage = '连接超时，请确保设备在附近且蓝牙已开启';
      await _cleanupConnection();
      return false;
    } on StateError {
      _errorMessage = '设备未找到，请重新扫描';
      await _cleanupConnection();
      return false;
    } catch (e) {
      _errorMessage = '连接失败: $e';
      await _cleanupConnection();
      return false;
    }
  }

  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  /// 开始监听连接状态变化
  void _startConnectionStateListener() {
    // 取消之前的监听
    _connectionStateSubscription?.cancel();

    if (_connectedDevice == null) return;

    // 监听连接状态变化
    _connectionStateSubscription = _connectedDevice!.connectionState.listen(
      (state) {
        if (state == BluetoothConnectionState.disconnected) {
          debugPrint('[NearLink] 连接状态监听: 连接已断开');
          _connectionStateSubscription?.cancel();
          _connectionStateSubscription = null;

          // 清理连接资源
          _txCharacteristic = null;
          _rxCharacteristic = null;
          _rxSubscription?.cancel();
          _rxSubscription = null;
          _connectedDevice = null;
          _stopHeartbeatMonitoring();

          _updateConnectionState(NearLinkConnectionState.disconnected);
          notifyListeners();
        }
      },
      onError: (error) {
        debugPrint('[NearLink] 连接状态监听错误: $error');
      },
    );
  }

  /// 清理连接资源
  Future<void> _cleanupConnection() async {
    try {
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
        _connectedDevice = null;
      }
    } catch (e) {
      // 清理连接时出错
    }
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _connectedDeviceIsIOSPeer = false;
    _stopHeartbeatMonitoring();
    _updateConnectionState(NearLinkConnectionState.disconnected);
    notifyListeners();
  }

  /// 发现服务和特征
  Future<void> _discoverServices() async {
    if (_connectedDevice == null) {
      throw Exception('设备未连接');
    }

    // 等待服务发现完成（iOS 可能需要更长时间）
    List<BluetoothService> services;
    try {
      services = await _connectedDevice!.discoverServices().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('服务发现超时');
        },
      );
    } catch (e) {
      rethrow;
    }

    bool foundNearLinkService = false;
    for (final service in services) {
      final serviceUuid = service.uuid.str.toUpperCase();

      // 支持完整格式和短格式（ffff 或 0000FFFF-0000-1000-8000-00805F9B34FB）
      final isNearLinkService =
          serviceUuid == NearLinkConstants.serviceUuid.toUpperCase() ||
              serviceUuid == 'FFFF' ||
              serviceUuid.contains('FFFF');

      if (isNearLinkService) {
        foundNearLinkService = true;

        for (final char in service.characteristics) {
          final charUuid = char.uuid.str.toUpperCase();
          // 支持完整格式和短格式
          final isTxChar =
              charUuid == NearLinkConstants.charTxUuid.toUpperCase() ||
                  charUuid == 'FF01' ||
                  charUuid.contains('FF01');
          final isRxChar =
              charUuid == NearLinkConstants.charRxUuid.toUpperCase() ||
                  charUuid == 'FF02' ||
                  charUuid.contains('FF02');

          if (isTxChar) {
            _txCharacteristic = char;

            // 订阅 TX 通知来接收数据
            if (char.properties.notify) {
              try {
                await _txCharacteristic!.setNotifyValue(true);

                // 等待订阅生效 - 增加等待时间
                await Future.delayed(const Duration(milliseconds: 200));

                // 检查订阅状态
                final notifying = _txCharacteristic!.isNotifying;

                if (!notifying) {
                  await Future.delayed(const Duration(milliseconds: 300));
                  await _txCharacteristic!.setNotifyValue(true);
                }

                // 取消之前的订阅
                await _rxSubscription?.cancel();

                // 使用 lastValueStream 接收所有数据通知
                _rxSubscription = _txCharacteristic!.lastValueStream.listen(
                  (data) {
                    // 每次收到通知都调用 _onDataReceived
                    // 它内部会处理粘包和分包
                    _onDataReceived(Uint8List.fromList(data));
                  },
                  onDone: () {},
                  onError: (_) {},
                );
              } catch (e) {
                debugPrint('[NearLink] 订阅 TX 通知失败: $e');
              }
            }
          } else if (isRxChar) {
            _rxCharacteristic = char;
          }
        }
        break;
      }
    }

    if (!foundNearLinkService) {
      throw Exception('对方设备不是 NearLink 设备或 GATT 服务未启动');
    }

    if (_txCharacteristic == null) {
      throw Exception('未找到 TX 特征值');
    }
    if (_rxCharacteristic == null) {
      throw Exception('未找到 RX 特征值');
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    final sentDisconnectSignal = await _sendDisconnectSignal();
    if (sentDisconnectSignal) {
      // 给对端一个很短的窗口接收主动断开通知，避免 UI 状态滞后。
      await Future.delayed(const Duration(milliseconds: 300));
    }

    _rxSubscription?.cancel();
    _rxSubscription = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;

    // 清理数据包缓冲区，避免影响下次传输
    _packetBuffer.clear();
    _connectedDeviceIsIOSPeer = false;
    _stopHeartbeatMonitoring();

    if (_isPeripheralConnected) {
      try {
        await _androidChannel.invokeMethod('disconnect');
      } on PlatformException catch (e) {
        debugPrint('[NearLink] 原生断开 Peripheral 连接失败: $e');
      } on MissingPluginException {
        debugPrint('[NearLink] 原生 disconnect 未实现');
      } catch (e) {
        debugPrint('[NearLink] 原生断开 Peripheral 连接异常: $e');
      }

      _isPeripheralConnected = false;
      _connectedCentralId = null;
      _connectedCentralName = null;
      _connectedCentralMtu = null;
    }

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }

    _updateConnectionState(NearLinkConnectionState.disconnected);
    notifyListeners();
  }

  Future<bool> _sendDisconnectSignal() async {
    final hasPeer = _isPeripheralConnected || _connectedDevice != null;
    if (!hasPeer) return false;

    try {
      final packet = NearLinkPacket.cancel(fileId: '');
      return await sendPacket(packet);
    } catch (e) {
      debugPrint('[NearLink] 发送断开通知失败: $e');
      return false;
    }
  }

  void handleRemoteDisconnectSignal() {
    final wasPeripheralConnected = _isPeripheralConnected;

    _rxSubscription?.cancel();
    _rxSubscription = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _packetBuffer.clear();
    _isPeripheralConnected = false;
    _connectedCentralId = null;
    _connectedCentralName = null;
    _connectedCentralMtu = null;
    _connectedDeviceIsIOSPeer = false;
    _errorMessage = '对方已断开连接';
    _stopHeartbeatMonitoring();

    final device = _connectedDevice;
    _connectedDevice = null;
    if (device != null) {
      unawaited(device.disconnect().catchError((_) {}));
    }
    if (wasPeripheralConnected && Platform.isAndroid) {
      unawaited(_androidChannel.invokeMethod('disconnect').catchError((error) {
        debugPrint('[NearLink] Android 原生断开远端连接失败: $error');
        return false;
      }));
    }

    _updateConnectionState(NearLinkConnectionState.disconnected);
    notifyListeners();
  }

  void _markPeerActive() {
    _lastPeerActivityAt = DateTime.now();
    _heartbeatInFlight = false;
  }

  void _startHeartbeatMonitoring() {
    _stopHeartbeatMonitoring();
    _markPeerActive();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: NearLinkConstants.heartbeatInterval),
      (_) => _heartbeatTick(),
    );
  }

  void _stopHeartbeatMonitoring() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastPeerActivityAt = null;
    _heartbeatInFlight = false;
  }

  Future<void> _heartbeatTick() async {
    if (!isConnected && !_isPeripheralConnected) {
      _stopHeartbeatMonitoring();
      return;
    }

    final lastActivity = _lastPeerActivityAt ?? DateTime.now();
    final idleFor = DateTime.now().difference(lastActivity);

    if (idleFor.inSeconds >= NearLinkConstants.peerTimeout) {
      handleRemoteDisconnectSignal();
      return;
    }

    if (_heartbeatInFlight) {
      return;
    }

    if (idleFor.inSeconds < NearLinkConstants.heartbeatInterval) {
      return;
    }

    _heartbeatInFlight = true;
    final success = await sendPacket(NearLinkPacket.ping());
    if (!success) {
      _heartbeatInFlight = false;
      debugPrint('[NearLink] 心跳发送失败，等待超时判定');
    }
  }

  void _handleInternalPacket(NearLinkPacket packet) {
    _markPeerActive();

    if (packet.type == PacketType.ping) {
      unawaited(sendPacket(NearLinkPacket.pong()).catchError((_) => false));
    }
  }

  /// 发送数据
  /// 支持两种模式：
  /// 1. Android/iOS 作为 Peripheral 被连接（调用原生方法）
  /// 2. Android 作为 Central 连接到外设（使用 _rxCharacteristic）
  /// 3. iOS 作为 Central 连接到 Android 外设（使用 _rxCharacteristic）
  Future<bool> sendData(Uint8List data) async {
    // 高频打印已禁用以提升性能
    // debugPrint('[NearLink] sendData 开始: 数据大小=${data.length} bytes');

    // 模式 1：作为 Peripheral 被连接，通过原生层发送（Android/iOS 都适用）
    if (_isPeripheralConnected) {
      return _sendDataAsPeripheral(data);
    }

    // 模式 2 和 3：使用 _rxCharacteristic 发送
    if (_rxCharacteristic == null || _connectedDevice == null) {
      _errorMessage =
          '未连接到设备: rx=${_rxCharacteristic != null}, device=${_connectedDevice != null}';
      return false;
    }

    // 检查连接状态
    try {
      final state = await _connectedDevice!.connectionState.first;
      if (state != BluetoothConnectionState.connected) {
        _errorMessage = '蓝牙连接已断开';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = '连接状态检查失败';
      return false;
    }

    try {
      // Android 向 iOS 发送时，使用更小的分块大小
      // iOS BLE MTU 最大为 185，减去 3 字节 ATT 头，实际可用约 182
      // 为了安全，使用 180 字节
      final bool isTargetIOS = _connectedDeviceIsIOSPeer;

      // 检查特征值是否支持不带响应写入
      final bool canWriteWithoutResponse =
          _rxCharacteristic!.properties.writeWithoutResponse;
      final int writeWindowSize =
          canWriteWithoutResponse ? (isTargetIOS ? 4 : 8) : 1;
      final pendingWrites = <Future<void>>[];

      final int chunkSize = isTargetIOS ? 180 : 512;
      // 高频打印已禁用以提升性能
      // debugPrint('[NearLink] sendData: chunkSize=$chunkSize, targetIOS=$isTargetIOS');
      int offset = 0;
      while (offset < data.length) {
        final end = (offset + chunkSize < data.length)
            ? offset + chunkSize
            : data.length;
        final chunk = data.sublist(offset, end);

        try {
          // 根据特征值属性选择写入模式
          final writeFuture = _rxCharacteristic!.write(
            chunk,
            withoutResponse: canWriteWithoutResponse,
          );
          pendingWrites.add(writeFuture);

          final shouldFlushWindow = pendingWrites.length >= writeWindowSize;
          if (shouldFlushWindow) {
            await Future.wait(pendingWrites, eagerError: true);
            pendingWrites.clear();
          }
        } catch (writeError) {
          // GATT_INVALID_HANDLE 通常表示连接已断开
          if (writeError.toString().contains('GATT_INVALID_HANDLE') ||
              writeError.toString().contains('133')) {
            _errorMessage = '连接已断开';
            _updateConnectionState(NearLinkConnectionState.disconnected);
            notifyListeners();
          } else {
            _errorMessage = '写入失败: $writeError';
          }
          return false;
        }
        offset = end;

        // 当 Android 作为 Central 向 iOS Peripheral 连续写入时，适度让出时间片，避免队列溢出。
        if (offset < data.length &&
            canWriteWithoutResponse &&
            isTargetIOS &&
            pendingWrites.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }

      if (pendingWrites.isNotEmpty) {
        await Future.wait(pendingWrites, eagerError: true);
      }
      return true;
    } catch (e) {
      _errorMessage = '发送失败: $e';
      return false;
    }
  }

  /// iOS 作为 Peripheral 时发送数据（通过原生层）
  /// iOS 作为 Peripheral 被 Android 连接时使用此方法
  Future<bool> _sendDataAsPeripheral(Uint8List data) async {
    try {
      // if (shouldLog) {
      //   debugPrint(
      //       '[NearLink] _sendDataAsPeripheral: 发送数据，大小=${data.length} bytes');
      // }
      // 直接将数据发送给 iOS，让 iOS 自己分块和队列管理
      // 这样可以减少 Flutter 和 iOS 之间的往返次数，提高效率
      final success = await _androidChannel.invokeMethod<bool>('sendData', {
            'data': data,
          }) ??
          false;

      // if (shouldLog) {
      //   debugPrint('[NearLink] _sendDataAsPeripheral: 发送结果=$success');
      // }
      return success;
    } catch (e) {
      _errorMessage = '发送失败: $e';
      // debugPrint('[NearLink] _sendDataAsPeripheral 发送失败: $_errorMessage');
      return false;
    }
  }

  /// 批量发送数据（用于 iOS 作为 Peripheral 时）
  Future<bool> sendDataBatch(List<Uint8List> packets) async {
    if (!_isPeripheralConnected) {
      _errorMessage = '未作为 Peripheral 连接';
      return false;
    }

    try {
      // 将多个包合并后一次性发送给原生层
      final success =
          await _androidChannel.invokeMethod<bool>('sendDataBatch', {
                'packets': packets.map((p) => p.toList()).toList(),
              }) ??
              false;

      return success;
    } catch (e) {
      _errorMessage = '批量发送失败: $e';
      debugPrint('[NearLink] sendDataBatch 失败: $_errorMessage');
      return false;
    }
  }

  /// 发送数据包
  Future<bool> sendPacket(NearLinkPacket packet) async {
    final encodedData = packet.encode();
    return sendData(encodedData);
  }

  Future<int> getPendingPeripheralNotificationCount() async {
    if (!_isPeripheralConnected || (!Platform.isAndroid && !Platform.isIOS)) {
      return 0;
    }

    try {
      final count = await _androidChannel
          .invokeMethod<int>('getPendingNotificationCount');
      return count ?? 0;
    } catch (e) {
      _errorMessage = '获取发送队列状态失败: $e';
      return -1;
    }
  }

  Future<bool> waitForPeripheralSendQueueDrained({
    Duration timeout = _androidPeripheralQueueDrainTimeout,
    Duration pollInterval = _androidPeripheralQueuePollInterval,
  }) async {
    if (!_isPeripheralConnected || (!Platform.isAndroid && !Platform.isIOS)) {
      return true;
    }

    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (!_isPeripheralConnected) {
        _errorMessage = '连接已断开';
        return false;
      }

      final pendingCount = await getPendingPeripheralNotificationCount();
      if (pendingCount == 0) {
        return true;
      }
      if (pendingCount < 0) {
        return false;
      }

      await Future.delayed(pollInterval);
    }

    _errorMessage = '等待原生发送队列清空超时';
    return false;
  }

  /// 数据接收回调（处理粘包问题）
  void _onDataReceived(Uint8List data) {
    // 将新数据添加到缓冲区
    _packetBuffer.addAll(data);

    // 持续解析直到缓冲区数据不足一个包头
    while (_packetBuffer.length >= NearLinkConstants.headerSize) {
      // 首先检查缓冲区开头是否是有效的包类型
      final firstByte = _packetBuffer[0];

      if (firstByte >= 0 && firstByte < PacketType.values.length) {
        // 尝试解析
        final packetData = Uint8List.fromList(_packetBuffer);
        final packet = NearLinkPacket.decode(packetData);

        if (packet != null) {
          // 验证解析结果的合理性
          if (!_isPacketValid(packet)) {
            _packetBuffer.removeAt(0);
            continue;
          }

          // 解析成功，检查数据是否完整
          final packetLength =
              NearLinkConstants.headerSize + packet.payloadSize;

          if (_packetBuffer.length >= packetLength) {
            // 数据完整，处理这个包
            final completePacket = NearLinkPacket.decode(
                Uint8List.fromList(_packetBuffer.sublist(0, packetLength)));

            if (completePacket != null) {
              // 从缓冲区移除已处理的数据
              _packetBuffer.removeRange(0, packetLength);

              _handleInternalPacket(completePacket);

              // 通知监听器
              _onPacketReceived?.call(completePacket);
              continue;
            } else {
              // 如果第二次 decode 失败，尝试跳过这个位置
              _packetBuffer.removeAt(0);
              continue;
            }
          } else {
            // 数据不完整，等待更多数据
            break;
          }
        }
      }

      // 如果开头不是有效包类型，查找真正的包起始位置
      final startIndex = _findPacketStart(_packetBuffer);

      if (startIndex > 0) {
        // 找到有效起始位置，跳过前面的乱序数据
        _packetBuffer.removeRange(0, startIndex);
      } else if (startIndex == -1) {
        // 没有找到有效的包起始，可能是噪音，清除缓冲区
        _packetBuffer.clear();
        break;
      } else {
        // 数据可能还不够，等待更多数据
        break;
      }
    }
  }

  /// 验证数据包字段的合理性
  bool _isPacketValid(NearLinkPacket packet) {
    final type = packet.type.index;
    final chunkIndex = packet.chunkIndex;
    final totalChunks = packet.totalChunks;

    // 对于 chunk 类型包，进行更严格的验证
    if (type == PacketType.chunk.index) {
      // totalChunks 必须大于 0
      if (totalChunks == 0) return false;
      // chunkIndex 必须小于 totalChunks
      if (chunkIndex >= totalChunks) return false;
      // chunkIndex 应该合理（最多支持 10GB 文件）
      if (chunkIndex > 25000000) return false; // 10GB / 440 bytes ≈ 23M chunks
    } else if (type == PacketType.chunkAck.index) {
      // chunkAck 包的 totalChunks 必须为 0
      if (totalChunks != 0) return false;
      // chunkAck 的 chunkIndex 应该合理（正常范围 0-50000）
      if (chunkIndex > 50000) return false;
    } else if (type == PacketType.handshake.index ||
        type == PacketType.handshakeAck.index ||
        type == PacketType.handshakeReject.index ||
        type == PacketType.fileInfo.index ||
        type == PacketType.fileInfoAck.index ||
        type == PacketType.fileInfoReject.index ||
        type == PacketType.transferComplete.index ||
        type == PacketType.transferCompleteAck.index ||
        type == PacketType.cancel.index) {
      // 这些类型的包 chunkIndex 必须为 0
      if (chunkIndex != 0) return false;
      // 对于 fileInfo 包，totalChunks 应该大于 0
      if (type == PacketType.fileInfo.index && totalChunks == 0) return false;
    } else {
      // 其他未知类型或 ping/pong/error/chunkNack
      if (chunkIndex > 100000) return false;
    }

    return true;
  }

  /// 查找数据包起始位置
  int _findPacketStart(List<int> buffer) {
    if (buffer.isEmpty) return -1;

    // 遍历缓冲区查找可能的包起始
    for (int i = 0; i < buffer.length; i++) {
      // 检查从位置 i 开始是否可能是一个有效的数据包
      if (i + NearLinkConstants.headerSize > buffer.length) {
        return -(i + 1); // 返回负数表示可能需要更多数据
      }

      // 检查 type 是否有效 (0-18)
      final type = buffer[i];
      if (type < 0 || type >= PacketType.values.length) {
        continue;
      }

      // 检查 chunkIndex 和 totalChunks 是否合理
      final chunkIndex = (buffer[i + 33] << 8) | buffer[i + 34];
      final totalChunks = (buffer[i + 35] << 8) | buffer[i + 36];
      final payloadSize = (buffer[i + 37] << 8) | buffer[i + 38];

      // 对于 chunk 类型包，进行更严格的验证
      if (type == PacketType.chunk.index) {
        if (totalChunks == 0) continue;
        if (chunkIndex >= totalChunks) continue;
        if (chunkIndex > 25000000) continue; // 最多支持 10GB 文件
      } else if (type == PacketType.chunkAck.index) {
        if (totalChunks != 0) continue;
        if (chunkIndex > 50000) continue;
      } else if (type == PacketType.handshake.index ||
          type == PacketType.handshakeAck.index ||
          type == PacketType.handshakeReject.index ||
          type == PacketType.fileInfo.index ||
          type == PacketType.fileInfoAck.index ||
          type == PacketType.fileInfoReject.index ||
          type == PacketType.transferComplete.index ||
          type == PacketType.transferCompleteAck.index ||
          type == PacketType.cancel.index) {
        if (chunkIndex != 0) continue;
        if (type == PacketType.fileInfo.index && totalChunks == 0) continue;
      } else {
        if (chunkIndex > 100000) continue;
      }

      // payloadSize 不应该超过 BLE MTU
      if (payloadSize > NearLinkConstants.maxChunkSize * 2) {
        continue;
      }

      return i;
    }

    return 0;
  }

  /// 数据包接收回调
  void Function(NearLinkPacket)? _onPacketReceived;

  /// 设置数据包接收回调
  void setPacketListener(void Function(NearLinkPacket) listener) {
    _onPacketReceived = listener;
  }

  /// 发送握手
  Future<bool> sendHandshake() async {
    final packet = NearLinkPacket.handshake(
      deviceName: _deviceName,
      deviceId: _deviceId,
    );
    return sendPacket(packet);
  }

  /// 检查蓝牙适配器状态
  Future<bool> isBluetoothAvailable() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// 检查是否正在扫描
  Future<bool> isScanning() async {
    return FlutterBluePlus.isScanning.first;
  }

  void _updateConnectionState(NearLinkConnectionState state) {
    _connectionState = state;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
