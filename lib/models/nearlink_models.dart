import 'dart:typed_data';

/// NearLink 数据包类型枚举
enum PacketType {
  handshake,
  handshakeAck,
  handshakeReject,
  fileInfo,
  fileInfoAck,
  fileInfoReject,
  chunk,
  chunkAck,
  chunkNack,
  transferComplete,
  transferCompleteAck,
  cancel,
  error,
  ping,
  pong,
}

/// NearLink 传输状态
enum TransferStatus {
  idle,
  connecting,
  handshaking,
  transferring,
  completed,
  failed,
  cancelled,
}

/// 设备连接状态
enum NearLinkConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
}

/// 文件传输信息
class FileTransfer {
  final String fileId;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String mimeType;
  final int totalChunks;
  final int currentChunk;
  final double progress;
  final TransferStatus status;
  final DateTime startTime;
  final String? errorMessage;

  const FileTransfer({
    required this.fileId,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.mimeType,
    required this.totalChunks,
    this.currentChunk = 0,
    this.progress = 0.0,
    this.status = TransferStatus.idle,
    required this.startTime,
    this.errorMessage,
  });

  FileTransfer copyWith({
    String? fileId,
    String? fileName,
    String? filePath,
    int? fileSize,
    String? mimeType,
    int? totalChunks,
    int? currentChunk,
    double? progress,
    TransferStatus? status,
    DateTime? startTime,
    String? errorMessage,
  }) {
    return FileTransfer(
      fileId: fileId ?? this.fileId,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      totalChunks: totalChunks ?? this.totalChunks,
      currentChunk: currentChunk ?? this.currentChunk,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      startTime: startTime ?? this.startTime,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// NearLink 数据包
class NearLinkPacket {
  final PacketType type;
  final String fileId;
  final int chunkIndex;
  final int totalChunks;
  final int payloadSize;
  final String checksum;
  final Uint8List payload;
  final int timestamp;
  final Map<String, dynamic>? metadata;

  static const int headerSize = 64;
  static const int maxPayloadSize = 512; // BLE 限制

  NearLinkPacket({
    required this.type,
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.payloadSize,
    required this.checksum,
    required this.payload,
    required this.timestamp,
    this.metadata,
  });

  /// 编码为字节数据
  Uint8List encode() {
    final header = BytesBuilder();
    // Type (1 byte)
    header.addByte(type.index);
    // FileId (32 bytes, UTF-8) - 移除连字符确保固定长度
    final normalizedFileId = fileId.replaceAll('-', '');
    final fileIdBytes = _padRight(normalizedFileId.codeUnits, 32);
    header.add(fileIdBytes);
    // ChunkIndex (2 bytes, big endian)
    header.add([(chunkIndex >> 8) & 0xFF, chunkIndex & 0xFF]);
    // TotalChunks (2 bytes, big endian)
    header.add([(totalChunks >> 8) & 0xFF, totalChunks & 0xFF]);
    // PayloadSize (2 bytes, big endian)
    header.add([(payloadSize >> 8) & 0xFF, payloadSize & 0xFF]);
    // Checksum (8 bytes, UTF-8)
    final checksumBytes = _padRight(checksum.codeUnits, 8);
    header.add(checksumBytes);
    // Timestamp (4 bytes, big endian)
    header.add([
      (timestamp >> 24) & 0xFF,
      (timestamp >> 16) & 0xFF,
      (timestamp >> 8) & 0xFF,
      timestamp & 0xFF,
    ]);
    // Reserved (13 bytes)
    header.add(List.filled(13, 0));

    final packet = BytesBuilder();
    packet.add(header.toBytes());
    packet.add(payload);
    return packet.toBytes();
  }

  /// 从字节数据解码
  static NearLinkPacket? decode(Uint8List data) {
    if (data.length < headerSize) return null;

    try {
      final type = PacketType.values[data[0]];
      final fileId = String.fromCharCodes(data.sublist(1, 33)).trim();
      final chunkIndex = (data[33] << 8) | data[34];
      final totalChunks = (data[35] << 8) | data[36];
      final payloadSize = (data[37] << 8) | data[38];
      final checksum = String.fromCharCodes(data.sublist(39, 47)).trim();
      final timestamp = (data[47] << 24) | (data[48] << 16) | (data[49] << 8) | data[50];

      if (data.length < headerSize + payloadSize) return null;

      final payload = data.sublist(headerSize, headerSize + payloadSize);

      // 解码 metadata
      Map<String, dynamic>? metadata;
      if (payload.isNotEmpty) {
        metadata = _decodeMetadata(payload);
      }

      return NearLinkPacket(
        type: type,
        fileId: fileId,
        chunkIndex: chunkIndex,
        totalChunks: totalChunks,
        payloadSize: payloadSize,
        checksum: checksum,
        payload: payload,
        timestamp: timestamp,
        metadata: metadata,
      );
    } catch (e) {
      return null;
    }
  }

  /// 解码 metadata
  static Map<String, dynamic>? _decodeMetadata(Uint8List payload) {
    try {
      final result = <String, dynamic>{};
      int i = 0;
      
      while (i < payload.length) {
        // 读取 key
        final keyStart = i;
        while (i < payload.length && payload[i] != 0) {
          i++;
        }
        if (i >= payload.length) break;
        
        final key = String.fromCharCodes(payload.sublist(keyStart, i));
        i++; // skip null terminator
        
        if (i >= payload.length) break;
        
        final type = payload[i++];
        
        switch (type) {
          case 1: // int
            if (i + 4 > payload.length) return result;
            final value = (payload[i] << 24) | (payload[i + 1] << 16) | 
                         (payload[i + 2] << 8) | payload[i + 3];
            result[key] = value;
            i += 4;
            break;
          case 2: // string
            if (i >= payload.length) return result;
            final len = payload[i++];
            if (i + len > payload.length) return result;
            result[key] = String.fromCharCodes(payload.sublist(i, i + len));
            i += len;
            break;
          case 3: // bytes
            if (i >= payload.length) return result;
            final len = payload[i++];
            if (i + len > payload.length) return result;
            result[key] = Uint8List.fromList(payload.sublist(i, i + len));
            i += len;
            break;
          default:
            break;
        }
        
        // 跳过 separator (0xFF)
        if (i < payload.length && payload[i] == 0xFF) {
          i++;
        }
      }
      
      return result;
    } catch (e) {
      return null;
    }
  }

  static List<int> _padRight(List<int> bytes, int length) {
    if (bytes.length >= length) return bytes.sublist(0, length);
    return [...bytes, ...List.filled(length - bytes.length, 0)];
  }

  /// 创建握手包
  factory NearLinkPacket.handshake({
    required String deviceName,
    required String deviceId,
  }) {
    final metadata = {
      'deviceName': deviceName,
      'deviceId': deviceId,
      'version': '1.0.0',
    };
    final payload = Uint8List.fromList(_encodeMetadata(metadata));

    return NearLinkPacket(
      type: PacketType.handshake,
      fileId: '',
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      metadata: metadata,
    );
  }

  /// 创建握手确认包 (用于响应握手请求)
  factory NearLinkPacket.handshakeAck({
    required String deviceName,
    required String deviceId,
  }) {
    final metadata = {
      'deviceName': deviceName,
      'deviceId': deviceId,
      'version': '1.0.0',
    };
    final payload = Uint8List.fromList(_encodeMetadata(metadata));

    return NearLinkPacket(
      type: PacketType.handshakeAck,
      fileId: '',
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      metadata: metadata,
    );
  }

  /// 创建文件信息包
  factory NearLinkPacket.fileInfo({
    required String fileId,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required int totalChunks,
    required Uint8List fileChecksum,
  }) {
    final metadata = {
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'totalChunks': totalChunks,
      'fileChecksum': fileChecksum,
    };
    final payload = Uint8List.fromList(_encodeMetadata(metadata));

    return NearLinkPacket(
      type: PacketType.fileInfo,
      fileId: fileId,
      chunkIndex: 0,
      totalChunks: totalChunks,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      metadata: metadata,
    );
  }

  /// 创建数据块包
  factory NearLinkPacket.chunk({
    required String fileId,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List data,
  }) {
    return NearLinkPacket(
      type: PacketType.chunk,
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      payloadSize: data.length,
      checksum: _calculateChecksum(data),
      payload: data,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// 创建块确认包
  factory NearLinkPacket.chunkAck({
    required String fileId,
    required int chunkIndex,
  }) {
    final payload = Uint8List.fromList('ACK'.codeUnits);
    return NearLinkPacket(
      type: PacketType.chunkAck,
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: 0,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// 创建传输完成包
  factory NearLinkPacket.transferComplete({
    required String fileId,
    required String fileChecksum,
  }) {
    final payload = Uint8List.fromList(fileChecksum.codeUnits);
    return NearLinkPacket(
      type: PacketType.transferComplete,
      fileId: fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// 创建取消包
  factory NearLinkPacket.cancel({required String fileId}) {
    final payload = Uint8List.fromList('CANCEL'.codeUnits);
    return NearLinkPacket(
      type: PacketType.cancel,
      fileId: fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: payload.length,
      checksum: _calculateChecksum(payload),
      payload: payload,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  static List<int> _encodeMetadata(Map<String, dynamic> metadata) {
    final result = <int>[];
    for (final entry in metadata.entries) {
      final key = entry.key;
      final value = entry.value;
      result.addAll(key.codeUnits);
      result.add(0);
      if (value is int) {
        result.add(1); // int type
        result.addAll(_intToBytes(value));
      } else if (value is String) {
        result.add(2); // string type
        result.add(value.length);
        result.addAll(value.codeUnits);
      } else if (value is Uint8List) {
        result.add(3); // bytes type
        result.add(value.length);
        result.addAll(value);
      }
      result.add(0xFF); // separator
    }
    return result;
  }

  static List<int> _intToBytes(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }

  static String _calculateChecksum(Uint8List data) {
    // 简化的 CRC32 校验
    int crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ (0xEDB88320 & ~((crc & 1) - 1));
      }
    }
    crc = ~crc;
    return crc.toRadixString(16).padLeft(8, '0');
  }

  @override
  String toString() {
    return 'NearLinkPacket(type: $type, fileId: $fileId, chunk: $chunkIndex/$totalChunks)';
  }
}

/// 设备类型枚举
enum DeviceType {
  phone,      // 手机
  tablet,     // 平板
  computer,   // 电脑
  audio,      // 音频设备 (耳机、音箱)
  watch,      // 手表/手环
  other,      // 其他设备
  unknown,    // 未知设备
}

/// 附近设备信息
class NearbyDevice {
  final String id;
  final String name;
  final int rssi;
  final bool isConnected;
  final DateTime lastSeen;
  final String? manufacturer;  // 制造商
  final DeviceType deviceType; // 设备类型

  const NearbyDevice({
    required this.id,
    required this.name,
    required this.rssi,
    this.isConnected = false,
    required this.lastSeen,
    this.manufacturer,
    this.deviceType = DeviceType.unknown,
  });

  /// 信号强度等级 (0-4)
  int get signalLevel {
    if (rssi >= -50) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -70) return 2;
    if (rssi >= -80) return 1;
    return 0;
  }

  /// 判断是否为可能的 NearLink 设备
  bool get isPossibleNearLinkDevice {
    // 名字包含 nearlink 关键字
    if (name.toLowerCase().contains('nearlink')) return true;
    
    // 过滤掉明显的非手机设备
    switch (deviceType) {
      case DeviceType.phone:
      case DeviceType.tablet:
        return true;
      case DeviceType.audio:
      case DeviceType.watch:
        // 音频设备和手表不太可能是 NearLink
        return false;
      default:
        // 未知设备，检查名字
        return _isLikelyMobile(name);
    }
  }

  /// 根据设备名称判断是否为移动设备
  static bool _isLikelyMobile(String name) {
    final lowerName = name.toLowerCase();
    // 常见品牌和设备标识
    final mobileKeywords = [
      'iphone', 'android', 'samsung', 'xiaomi', 'huawei', 'oppo', 'vivo',
      'oneplus', 'realme', 'motorola', 'lg', 'sony', 'google pixel',
      'pixel', 'redmi', 'poco', 'honor', 'nokia', 'asus', 'lenovo',
      'ipad', 'galaxy', 'mate', 'mi ', 'note', 'pro', 'ultra', 'max',
    ];
    return mobileKeywords.any((keyword) => lowerName.contains(keyword));
  }

  /// 根据设备名称推断设备类型
  static DeviceType inferDeviceType(String name) {
    final lowerName = name.toLowerCase();
    
    if (lowerName.contains('iphone') || lowerName.contains('android')) {
      return DeviceType.phone;
    }
    if (lowerName.contains('ipad') || lowerName.contains('tablet')) {
      return DeviceType.tablet;
    }
    if (lowerName.contains('macbook') || lowerName.contains('imac') || 
        lowerName.contains('windows') || lowerName.contains('laptop')) {
      return DeviceType.computer;
    }
    if (lowerName.contains('airpods') || lowerName.contains('headphone') ||
        lowerName.contains('earbuds') || lowerName.contains('speaker') ||
        lowerName.contains('buds') || lowerName.contains('耳机') ||
        lowerName.contains('音响')) {
      return DeviceType.audio;
    }
    if (lowerName.contains('watch') || lowerName.contains('band') ||
        lowerName.contains('fitbit') || lowerName.contains('手表') ||
        lowerName.contains('手环')) {
      return DeviceType.watch;
    }
    if (_isLikelyMobile(lowerName)) {
      return DeviceType.phone;
    }
    return DeviceType.unknown;
  }

  /// 获取设备类型图标
  String get deviceTypeIcon {
    switch (deviceType) {
      case DeviceType.phone:
        return '📱';
      case DeviceType.tablet:
        return '📲';
      case DeviceType.computer:
        return '💻';
      case DeviceType.audio:
        return '🎧';
      case DeviceType.watch:
        return '⌚';
      default:
        return '📟';
    }
  }

  NearbyDevice copyWith({
    String? id,
    String? name,
    int? rssi,
    bool? isConnected,
    DateTime? lastSeen,
    String? manufacturer,
    DeviceType? deviceType,
  }) {
    return NearbyDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      isConnected: isConnected ?? this.isConnected,
      lastSeen: lastSeen ?? this.lastSeen,
      manufacturer: manufacturer ?? this.manufacturer,
      deviceType: deviceType ?? this.deviceType,
    );
  }

  @override
  String toString() {
    return 'NearbyDevice(id: $id, name: $name, rssi: $rssi, type: $deviceType)';
  }
}
