import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:mime/mime.dart';
import '../bluetooth/nearlink_bluetooth_service.dart';
import '../models/nearlink_models.dart';

/// 文件传输服务
class FileTransferService extends ChangeNotifier {
  static final FileTransferService _instance = FileTransferService._internal();
  factory FileTransferService() => _instance;
  FileTransferService._internal();

  final NearLinkBluetoothService _bluetoothService = NearLinkBluetoothService();
  final Uuid _uuid = const Uuid();

  final Map<String, FileTransfer> _activeTransfers = {};
  final List<FileTransfer> _transferHistory = [];
  final Map<String, List<int>> _receivedData = {};
  final Map<String, Set<int>> _receivedChunks = {};  // 追踪每个文件已收到的 chunk 索引

  StreamSubscription<NearLinkPacket>? _packetSubscription;
  Completer<bool>? _transferCompleter;
  Completer<bool>? _transferCompleteCompleter;

  // 握手事件流
  final StreamController<String> _handshakeController =
      StreamController<String>.broadcast();
  Stream<String> get onHandshakeReceived => _handshakeController.stream;

  // 文件保存完成事件流
  final StreamController<String> _fileSavedController =
      StreamController<String>.broadcast();
  Stream<String> get onFileSaved => _fileSavedController.stream;

  // UI 刷新节流（使用时间戳而非重置定时器）
  DateTime? _lastNotifyTime;
  static const _notifyThrottleDuration = Duration(milliseconds: 100); // 100ms 足够流畅

  // Getters
  List<FileTransfer> get activeTransfers => _activeTransfers.values.toList();
  List<FileTransfer> get transferHistory => List.unmodifiable(_transferHistory);
  FileTransfer? get currentTransfer =>
      _activeTransfers.isNotEmpty ? _activeTransfers.values.first : null;

  /// 初始化
  void initialize() {
    _bluetoothService.setPacketListener(_handlePacket);
  }

  /// 准备发送文件（可指定是否压缩图片）
  /// [compressImage] - 是否压缩图片文件，仅对图片有效
  Future<FileTransfer?> prepareFile(String filePath, {bool compressImage = false}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      final fileName = filePath.split('/').last;
      final mimeType = lookupMimeType(fileName) ?? 'application/octet-stream';

      // 读取文件数据
      Uint8List fileData = await file.readAsBytes();
      
      // 如果需要压缩且是图片文件，进行压缩
      if (compressImage && mimeType.startsWith('image/')) {
        final compressed = await _compressImage(fileData, fileName);
        if (compressed != null) {
          fileData = compressed;
        }
      }

      // 生成 fileId 并移除连字符，确保与数据包编码一致
      final fileId = _uuid.v4().replaceAll('-', '');
      final finalSize = fileData.length;

      // 计算分块数
      final totalChunks = (finalSize / NearLinkConstants.maxChunkSize).ceil();

      final transfer = FileTransfer(
        fileId: fileId,
        fileName: fileName,
        filePath: filePath,
        fileSize: finalSize,
        mimeType: mimeType,
        totalChunks: totalChunks,
        status: TransferStatus.idle,
        startTime: DateTime.now(),
        isOutgoing: true,  // 标记为发送传输
      );

      // 保存文件数据供后续发送
      _receivedData[fileId] = fileData;
      _activeTransfers[fileId] = transfer;

      notifyListeners();
      return transfer;
    } catch (e) {
      return null;
    }
  }

  /// 准备发送文件（从字节数据，常用于 image_picker）
  Future<FileTransfer?> prepareFileWithBytes(String fileName, Uint8List fileData, {bool compressImage = false}) async {
    try {
      debugPrint('[FileTransfer] prepareFileWithBytes: 文件=$fileName, 大小=${fileData.length} bytes');
      final mimeType = lookupMimeType(fileName) ?? 'application/octet-stream';
      
      // 如果需要压缩且是图片文件，进行压缩
      Uint8List processedData = fileData;
      if (compressImage && mimeType.startsWith('image/')) {
        final compressed = await _compressImage(fileData, fileName);
        if (compressed != null) {
          processedData = compressed;
        }
      }

      // 生成 fileId
      final fileId = _uuid.v4().replaceAll('-', '');
      final finalSize = processedData.length;

      // 计算分块数
      final totalChunks = (finalSize / NearLinkConstants.maxChunkSize).ceil();

      final transfer = FileTransfer(
        fileId: fileId,
        fileName: fileName,
        filePath: '',  // 字节数据无路径
        fileSize: finalSize,
        mimeType: mimeType,
        totalChunks: totalChunks,
        status: TransferStatus.idle,
        startTime: DateTime.now(),
        isOutgoing: true,  // 标记为发送传输
      );

      // 保存文件数据供后续发送
      _receivedData[fileId] = processedData;
      _activeTransfers[fileId] = transfer;

      notifyListeners();
      return transfer;
    } catch (e) {
      return null;
    }
  }

  /// 开始发送文件
  Future<bool> startSend(String fileId) async {
    final transfer = _activeTransfers[fileId];
    // 检查连接状态：作为 Central 连接到外设，或作为 Peripheral 被连接
    final isConnected = _bluetoothService.isConnected || _bluetoothService.isPeripheralConnected;
    
    if (transfer == null) {
      return false;
    }
    
    if (!isConnected) {
      return false;
    }

    _transferCompleter = Completer<bool>();

    try {
      // 发送文件信息
      final fileData = _receivedData[fileId];
      if (fileData == null) {
        return false;
      }
      
      final fileChecksum = _calculateChecksum(Uint8List.fromList(fileData));
      final fileInfoPacket = NearLinkPacket.fileInfo(
        fileId: fileId,
        fileName: transfer.fileName,
        fileSize: transfer.fileSize,
        mimeType: transfer.mimeType,
        totalChunks: transfer.totalChunks,
        fileChecksum: Uint8List.fromList(fileChecksum.codeUnits),
      );

      _updateTransfer(fileId, status: TransferStatus.transferring);
      final sendResult = await _bluetoothService.sendPacket(fileInfoPacket);
      if (!sendResult) {
        _updateTransfer(fileId, status: TransferStatus.failed, errorMessage: '发送文件信息失败');
        return false;
      }

      // 等待确认
      final confirmed = await _transferCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          return false;
        },
      );

      if (!confirmed) {
        _updateTransfer(fileId, status: TransferStatus.failed, errorMessage: '对方未确认接收');
        return false;
      }

      // 开始发送数据块
      await _sendChunks(fileId, Uint8List.fromList(fileData));

      return true;
    } catch (e) {
      _updateTransfer(fileId, status: TransferStatus.failed, errorMessage: e.toString());
      return false;
    }
  }

  /// 发送数据块
  Future<void> _sendChunks(String fileId, Uint8List data) async {
    final totalChunks = (data.length / NearLinkConstants.maxChunkSize).ceil();

    for (int i = 0; i < totalChunks; i++) {
      final start = i * NearLinkConstants.maxChunkSize;
      final end = (start + NearLinkConstants.maxChunkSize).clamp(0, data.length);
      final chunk = data.sublist(start, end);

      final packet = NearLinkPacket.chunk(
        fileId: fileId,
        chunkIndex: i,
        totalChunks: totalChunks,
        data: Uint8List.fromList(chunk),
      );

      try {
        final sendResult = await _bluetoothService.sendPacket(packet);
        if (!sendResult) {
          _updateTransfer(fileId, status: TransferStatus.failed, errorMessage: '发送失败');
          return;
        }
      } catch (e) {
        _updateTransfer(fileId, status: TransferStatus.failed, errorMessage: e.toString());
        return;
      }
      
      // 发送成功后立即更新进度（不等 chunkAck，使用乐观更新）
      _updateTransfer(
        fileId,
        currentChunk: i + 1,
        progress: (i + 1) / totalChunks,
      );
    }

    // 等待一小段时间确保最后一个 chunk 被对方接收
    // BLE 传输可能需要一些时间才能完全到达对方
    await Future.delayed(const Duration(milliseconds: 300));

    // 创建完成确认等待器
    _transferCompleteCompleter = Completer<bool>();

    // 发送完成包（带重试机制）
    const maxRetries = 3;
    bool ackReceived = false;

    for (int retry = 0; retry < maxRetries && !ackReceived; retry++) {
      // 发送完成包
      final completePacket = NearLinkPacket.transferComplete(
        fileId: fileId,
        fileChecksum: _calculateChecksum(data),
      );
      await _bluetoothService.sendPacket(completePacket);

      // 等待确认，最多等待 2 秒
      ackReceived = await _transferCompleteCompleter!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );

      if (!ackReceived && retry < maxRetries - 1) {
        // 没收到确认，等待后重试
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    _transferCompleteCompleter = null;

    _updateTransfer(fileId, status: TransferStatus.completed);
    _cleanup(fileId);
  }

  /// 处理接收到的数据包
  Future<void> _handlePacket(NearLinkPacket packet) async {
    switch (packet.type) {
      case PacketType.handshake:
        await _handleHandshake(packet);
        break;
      case PacketType.handshakeAck:
        _handleHandshakeAck(packet);
        break;
      case PacketType.fileInfo:
        await _handleFileInfo(packet);
        break;
      case PacketType.fileInfoAck:
        _handleFileInfoAck(packet);
        break;
      case PacketType.chunk:
        _handleChunk(packet);
        break;
      case PacketType.chunkAck:
        _handleChunkAck(packet);
        break;
      case PacketType.transferComplete:
        await _handleTransferComplete(packet);
        break;
      case PacketType.transferCompleteAck:
        _handleTransferCompleteAck(packet);
        break;
      case PacketType.cancel:
        _handleCancel(packet);
        break;
      default:
        break;
    }
  }

  /// 处理握手响应
  void _handleHandshakeAck(NearLinkPacket packet) {
    // 握手响应确认
  }

  /// 处理文件信息确认
  void _handleFileInfoAck(NearLinkPacket packet) {
    // 找到对应的传输并完成等待
    for (final transfer in _activeTransfers.values) {
      if (transfer.fileId == packet.fileId) {
        if (_transferCompleter != null && !_transferCompleter!.isCompleted) {
          _transferCompleter!.complete(true);
        }
        break;
      }
    }
  }

  /// 处理传输完成确认
  void _handleTransferCompleteAck(NearLinkPacket packet) {
    // 完成确认到达，通知发送方
    if (_transferCompleteCompleter != null && !_transferCompleteCompleter!.isCompleted) {
      _transferCompleteCompleter!.complete(true);
    }
  }

  /// 处理握手
  Future<void> _handleHandshake(NearLinkPacket packet) async {
    String? deviceName;
    
    if (packet.metadata != null) {
      deviceName = packet.metadata!['deviceName'] as String?;
      
      // 通知监听器有设备连接过来（被动连接）
      if (deviceName != null && deviceName.isNotEmpty) {
        _handshakeController.add(deviceName);
      }
    }

    // 发送握手响应
    final ackPacket = NearLinkPacket.handshakeAck(
      deviceName: _bluetoothService.deviceName,
      deviceId: _bluetoothService.deviceName,
    );
    
    await _bluetoothService.sendPacket(ackPacket);
  }

  /// 处理文件信息
  Future<void> _handleFileInfo(NearLinkPacket packet) async {
    if (packet.metadata == null) {
      return;
    }

    final fileName = packet.metadata!['fileName'] as String;
    final fileSize = packet.metadata!['fileSize'] as int;
    final mimeType = packet.metadata!['mimeType'] as String;
    final totalChunks = packet.metadata!['totalChunks'] as int;

    final transfer = FileTransfer(
      fileId: packet.fileId,
      fileName: fileName,
      filePath: '',
      fileSize: fileSize,
      mimeType: mimeType,
      totalChunks: totalChunks,
      status: TransferStatus.transferring,
      startTime: DateTime.now(),
    );

    _activeTransfers[packet.fileId] = transfer;
    _receivedData[packet.fileId] = [];
    _receivedChunks[packet.fileId] = {};  // 初始化 chunk 追踪集合

    // 发送确认
    await _bluetoothService.sendPacket(NearLinkPacket(
      type: PacketType.fileInfoAck,
      fileId: packet.fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: 0,
      checksum: '00000000',
      payload: Uint8List(0),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));

    // 通知 UI 有新文件开始接收
    notifyListeners();
  }

  /// 处理数据块
  void _handleChunk(NearLinkPacket packet) {
    final data = _receivedData[packet.fileId];
    if (data == null) {
      return;
    }

    // 追踪已收到的 chunk
    final receivedSet = _receivedChunks[packet.fileId];
    if (receivedSet != null && !receivedSet.contains(packet.chunkIndex)) {
      receivedSet.add(packet.chunkIndex);
      data.addAll(packet.payload);
    }

    // 每次都更新内部数据
    _updateTransfer(
      packet.fileId,
      currentChunk: packet.chunkIndex + 1,
      progress: (packet.chunkIndex + 1) / packet.totalChunks,
    );

    // 发送块确认（fire-and-forget，不阻塞接收）
    _bluetoothService.sendPacket(NearLinkPacket.chunkAck(
      fileId: packet.fileId,
      chunkIndex: packet.chunkIndex,
    )).catchError((e) {
      return false;
    });

    // 检查是否收到了所有 chunk，如果是则自动完成传输
    _tryAutoCompleteTransfer(packet.fileId, packet.totalChunks);
  }

  /// 检查是否收到所有 chunk
  bool _checkAllChunksReceived(String fileId, int totalChunks) {
    final receivedSet = _receivedChunks[fileId];
    if (receivedSet == null) return false;
    
    // 检查是否收到了所有 chunk
    return receivedSet.length >= totalChunks;
  }

  /// 尝试自动完成传输（当收到所有 chunk 但没收到 transferComplete 时）
  Future<void> _tryAutoCompleteTransfer(String fileId, int totalChunks) async {
    if (!_checkAllChunksReceived(fileId, totalChunks)) return;
    
    final data = _receivedData[fileId];
    if (data == null) return;
    
    // 检查是否已经完成
    final transfer = _activeTransfers[fileId];
    if (transfer == null || transfer.status == TransferStatus.completed) return;
    
    debugPrint('[NearLink] 已收到所有 $totalChunks 个 chunk，自动完成传输');
    
    // 保存文件
    await _saveFile(fileId, Uint8List.fromList(data));
    
    _updateTransfer(fileId, status: TransferStatus.completed);
    
    // 发送完成确认
    await _bluetoothService.sendPacket(NearLinkPacket(
      type: PacketType.transferCompleteAck,
      fileId: fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: 0,
      checksum: '',
      payload: Uint8List(0),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));
    
    _cleanup(fileId);
  }

  /// 处理块确认
  void _handleChunkAck(NearLinkPacket packet) {
    // 发送方收到确认，更新已确认的块计数
    final transfer = _activeTransfers[packet.fileId];
    if (transfer == null) return;

    final confirmedChunk = packet.chunkIndex + 1;
    final totalChunks = transfer.totalChunks;

    // 计算进度（已确认的块 / 总块数）
    final progress = totalChunks > 0 ? confirmedChunk / totalChunks : 0.0;

    // 只在进度真正变化时才更新
    if (transfer.currentChunk != confirmedChunk || transfer.progress != progress) {
      _updateTransfer(
        packet.fileId,
        currentChunk: confirmedChunk,
        progress: progress,
      );
    }
  }

  /// 处理传输完成
  Future<void> _handleTransferComplete(NearLinkPacket packet) async {
    final data = _receivedData[packet.fileId];
    if (data == null) return;

    // 保存文件
    await _saveFile(packet.fileId, Uint8List.fromList(data));

    _updateTransfer(packet.fileId, status: TransferStatus.completed);

    // 发送完成确认
    await _bluetoothService.sendPacket(NearLinkPacket(
      type: PacketType.transferCompleteAck,
      fileId: packet.fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: 0,
      checksum: '',
      payload: Uint8List(0),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));

    _cleanup(packet.fileId);
  }

  /// 处理取消
  void _handleCancel(NearLinkPacket packet) {
    _updateTransfer(packet.fileId, status: TransferStatus.cancelled);
    _cleanup(packet.fileId);
  }

  /// 保存接收到的文件
  /// Android: /storage/emulated/0/NearLink/
  /// iOS: 应用 Documents/NearLink/ (可通过 Finder 访问)
  Future<String?> _saveFile(String fileId, Uint8List data) async {
    final transfer = _activeTransfers[fileId];
    if (transfer == null) return null;

    try {
      // 检查并请求存储权限
      await _requestStoragePermission();

      // 根据平台选择保存路径
      String directoryPath;
      if (Platform.isAndroid) {
        // Android: 保存到根目录的 NearLink 文件夹
        // 路径: /storage/emulated/0/NearLink/
        directoryPath = '/storage/emulated/0/NearLink';
      } else {
        // iOS: 保存到共享的 Documents 目录
        final appDir = await getApplicationDocumentsDirectory();
        directoryPath = '${appDir.path}/NearLink';
      }
      
      // 生成 UUID 文件名，保留原始扩展名
      final extension = _getFileExtension(transfer.fileName);
      final uuidFileName = '$fileId$extension';
      final savePath = '$directoryPath/$uuidFileName';

      // 创建目录
      final saveDir = Directory(directoryPath);
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      // 写入文件
      final file = File(savePath);
      await file.writeAsBytes(data);
      _fileSavedController.add(savePath);
      return savePath;
    } catch (e) {
      // 保存失败时尝试备用方案：应用私有目录
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final extension = _getFileExtension(transfer.fileName);
        final uuidFileName = '$fileId$extension';
        final backupPath = '${appDir.path}/NearLink/$uuidFileName';
        final backupDir = Directory('${appDir.path}/NearLink');
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        final file = File(backupPath);
        await file.writeAsBytes(data);
        _fileSavedController.add(backupPath);
        return backupPath;
      } catch (_) {
        return null;
      }
    }
  }
  
  /// 获取文件扩展名
  String _getFileExtension(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot > 0 && lastDot < fileName.length - 1) {
      return fileName.substring(lastDot);
    }
    return '';
  }

  /// 请求存储权限
  Future<void> _requestStoragePermission() async {
    // 检查是否已有存储权限
    if (await Permission.storage.isGranted) {
      return;
    }

    // Android 11+ 需要 MANAGE_EXTERNAL_STORAGE 权限才能写入外部存储根目录
    if (await Permission.manageExternalStorage.isGranted) {
      return;
    }

    // 请求 MANAGE_EXTERNAL_STORAGE 权限
    final status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      // 如果用户拒绝，尝试请求基本存储权限
      await Permission.storage.request();
    }
  }

  /// 判断是否为图片文件
  bool _isImageFile(String fileName) {
    final ext = fileName.toLowerCase().split('.').last;
    return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'].contains(ext);
  }

  /// 取消传输
  Future<void> cancelTransfer(String fileId) async {
    await _bluetoothService.sendPacket(NearLinkPacket.cancel(fileId: fileId));
    _updateTransfer(fileId, status: TransferStatus.cancelled);
    _cleanup(fileId);
  }

  /// 清理传输数据
  void _cleanup(String fileId) {
    final completedTransfer = _activeTransfers[fileId];
    _receivedData.remove(fileId);
    _receivedChunks.remove(fileId);  // 清理 chunk 追踪
    
    if (completedTransfer != null) {
      _transferHistory.insert(0, completedTransfer);
    }
    
    // 延迟移除传输对象，给 UI 时间检测 completed 状态并自动返回
    // 这样 Selector 能在 currentTransfer 仍存在时检测到 completed 状态
    Future.delayed(const Duration(milliseconds: 1500), () {
      _activeTransfers.remove(fileId);
      // 使用立即刷新确保 UI 立即更新
      _notifyListenersImmediate();
    });
  }

  void _updateTransfer(
    String fileId, {
    TransferStatus? status,
    int? currentChunk,
    double? progress,
    String? errorMessage,
  }) {
    final transfer = _activeTransfers[fileId];
    if (transfer == null) return;

    _activeTransfers[fileId] = transfer.copyWith(
      status: status,
      currentChunk: currentChunk,
      progress: progress,
      errorMessage: errorMessage,
    );
    
    // 使用时间戳节流：每 100ms 最多刷新一次 UI
    final now = DateTime.now();
    if (_lastNotifyTime == null || 
        now.difference(_lastNotifyTime!) >= _notifyThrottleDuration) {
      _lastNotifyTime = now;
      notifyListeners();
    }
  }
  
  /// 立即刷新 UI（用于关键状态变化）
  void _notifyListenersImmediate() {
    _lastNotifyTime = DateTime.now();
    notifyListeners();
  }

  /// 压缩图片
  /// 目标：压缩到原大小的 50% 或最大 200KB，取较小值
  Future<Uint8List?> _compressImage(Uint8List imageData, String fileName) async {
    try {
      // 获取临时目录用于存储压缩结果
      final tempDir = await getTemporaryDirectory();
      final targetPath = '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      
      // 确定目标质量：从 80 开始，根据文件大小调整
      int quality = 80;
      
      // 压缩循环，逐步降低质量直到文件大小合适
      while (quality > 20) {
        final result = await FlutterImageCompress.compressWithList(
          imageData,
          quality: quality,
          format: CompressFormat.jpeg,
          minWidth: 1920,  // 最大宽度
          minHeight: 1920, // 最大高度
          keepExif: false, // 不保留 EXIF 信息
        );
        
        // 如果压缩后大小小于 200KB 或质量已降至最低，接受结果
        if (result.length < 200 * 1024 || quality <= 30) {
          // 删除临时文件
          try {
            await File(targetPath).delete();
          } catch (_) {}
          return result;
        }
        
        // 继续降低质量
        quality -= 15;
      }
      
      // 最后一次尝试，即使文件较大也返回
      final result = await FlutterImageCompress.compressWithList(
        imageData,
        quality: 20,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      
      // 删除临时文件
      try {
        await File(targetPath).delete();
      } catch (_) {}
      
      return result;
    } catch (e) {
      debugPrint('[FileTransfer] 图片压缩失败: $e');
      return null;
    }
  }

  /// 计算校验和
  String _calculateChecksum(Uint8List data) {
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
  void dispose() {
    _packetSubscription?.cancel();
    _handshakeController.close();
    super.dispose();
  }
}
