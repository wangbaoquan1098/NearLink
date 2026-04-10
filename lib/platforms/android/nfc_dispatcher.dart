import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import '../../bluetooth/nearlink_bluetooth_service.dart';

/// NFC 事件类型
enum NfcEvent {
  tagDetected,
  sessionStarted,
  sessionClosed,
  error,
}

/// NFC 触发回调
typedef NfcTriggerCallback = void Function(String? deviceId);

/// NFC 调度器 - Android 专用
class NfcDispatcher extends ChangeNotifier {
  static final NfcDispatcher _instance = NfcDispatcher._internal();
  factory NfcDispatcher() => _instance;
  NfcDispatcher._internal();

  final NearLinkBluetoothService _bluetoothService = NearLinkBluetoothService();

  bool _isListening = false;
  NfcEvent? _lastEvent;
  String? _lastError;
  NfcTriggerCallback? _onTrigger;

  // Getters
  bool get isListening => _isListening;
  NfcEvent? get lastEvent => _lastEvent;
  String? get lastError => _lastError;

  /// 检查 NFC 是否可用
  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) {
      _lastError = 'NFC 仅支持 Android 设备';
      return false;
    }

    try {
      final available = await NfcManager.instance.isAvailable();
      if (!available) {
        _lastError = '设备不支持 NFC';
      }
      return available;
    } catch (e) {
      _lastError = 'NFC 检查失败: $e';
      return false;
    }
  }

  /// 开始监听 NFC 事件
  Future<void> startListening({NfcTriggerCallback? onTrigger}) async {
    if (!Platform.isAndroid) return;
    if (_isListening) return;

    _onTrigger = onTrigger;
    _lastError = null;

    final available = await isAvailable();
    if (!available) {
      notifyListeners();
      return;
    }

    try {
      _isListening = true;
      _lastEvent = NfcEvent.sessionStarted;
      notifyListeners();

      // 启动 NFC 会话
      await NfcManager.instance.startSession(
        pollingOptions: {
          NfcPollingOption.iso14443,
          NfcPollingOption.iso15693,
        },
        onDiscovered: _handleTagDiscovered,
      );
    } catch (e) {
      _isListening = false;
      _lastError = 'NFC 启动失败: $e';
      _lastEvent = NfcEvent.error;
      notifyListeners();
    }
  }

  /// 停止监听 NFC 事件
  Future<void> stopListening() async {
    if (!_isListening) return;

    try {
      await NfcManager.instance.stopSession();
      _isListening = false;
      _lastEvent = NfcEvent.sessionClosed;
      notifyListeners();
    } catch (e) {
      // NFC 停止失败
    }
  }

  /// 处理标签发现
  Future<void> _handleTagDiscovered(NfcTag tag) async {
    _lastEvent = NfcEvent.tagDetected;
    notifyListeners();

    try {
      // 读取 NDEF 数据
      final ndef = Ndef.from(tag);
      if (ndef == null) {
        _lastError = '不支持的 NFC 标签';
        notifyListeners();
        return;
      }

      // 尝试读取记录
      final cachedMessage = ndef.cachedMessage;
      if (cachedMessage == null) {
        _lastError = 'NFC 标签无数据';
        notifyListeners();
        return;
      }

      for (final record in cachedMessage.records) {
        // 解析文本记录
        if (record.typeNameFormat == NdefTypeNameFormat.nfcWellknown) {
          final payload = record.payload;
          if (payload.isNotEmpty && payload[0] == 0x02) {
            // UTF-8 编码的文本
            final languageCodeLength = payload[0] & 0x3F;
            final text = String.fromCharCodes(
              payload.sublist(1 + languageCodeLength),
            );

            // 提取设备 ID（格式: nearlink:deviceId）
            if (text.startsWith('nearlink:')) {
              final deviceId = text.substring(9);
              _onTrigger?.call(deviceId);

              // 触发蓝牙扫描
              await _bluetoothService.startScan();
            }
          }
          // 解析 URI 记录
          else if (payload.isNotEmpty && payload[0] == 0x01) {
            final uriCode = payload[1];
            final prefix = _uriPrefixes[uriCode] ?? '';
            final uri = prefix + String.fromCharCodes(payload.sublist(2));

            if (uri.startsWith('nearlink://')) {
              final deviceId = uri.substring(11);
              _onTrigger?.call(deviceId);
              await _bluetoothService.startScan();
            }
          }
        }
      }

      notifyListeners();
    } catch (e) {
      _lastError = 'NFC 读取失败: $e';
      _lastEvent = NfcEvent.error;
      notifyListeners();
    }
  }

  /// URI 前缀映射表
  static const Map<int, String> _uriPrefixes = {
    0x00: '',
    0x01: 'http://www.',
    0x02: 'https://www.',
    0x03: 'http://',
    0x04: 'https://',
    0x05: 'tel:',
    0x06: 'mailto:',
    0x07: 'ftp://anonymous:anonymous@',
    0x08: 'ftp://ftp.',
    0x09: 'ftps://',
    0x0A: 'sftp://',
    0x0B: 'smb://',
    0x0C: 'nfs://',
    0x0D: 'ftp://',
    0x0E: 'dav://',
    0x0F: 'news:',
    0x10: 'telnet://',
    0x11: 'imap:',
    0x12: 'rtsp://',
    0x13: 'urn:',
    0x14: 'pop:',
    0x15: 'sip:',
    0x16: 'sips:',
    0x17: 'tftp:',
    0x18: 'btspp://',
    0x19: 'btl2cap://',
    0x1A: 'btgoep://',
    0x1B: 'tcpobex://',
    0x1C: 'irdaobex://',
    0x1D: 'file://',
    0x1E: 'urn:epc:id:',
    0x1F: 'urn:epc:tag:',
    0x20: 'urn:epc:pat:',
    0x21: 'urn:epc:raw:',
    0x22: 'urn:epc:',
    0x23: 'urn:nfc:',
  };

  /// 写入 NFC 标签（用于配对）
  Future<bool> writeNdefRecord(String deviceId) async {
    if (!Platform.isAndroid) return false;

    final available = await isAvailable();
    if (!available) return false;

    try {
      // 创建 NDEF 消息
      final message = NdefMessage([
        NdefRecord.createText('nearlink:$deviceId'),
      ]);

      await NfcManager.instance.startSession(
        pollingOptions: {
          NfcPollingOption.iso14443,
          NfcPollingOption.iso15693,
        },
        onDiscovered: (tag) async {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            await NfcManager.instance.stopSession();
            return;
          }

          try {
            await ndef.write(message);
            await NfcManager.instance.stopSession();
          } catch (e) {
            await NfcManager.instance.stopSession();
          }
        },
      );

      return true;
    } catch (e) {
      _lastError = 'NFC 写入失败: $e';
      return false;
    }
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}
