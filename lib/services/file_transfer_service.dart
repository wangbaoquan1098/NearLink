import 'dart:async';
import 'dart:io';
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
  final Map<String, Set<int>> _receivedChunks = {}; // 追踪每个文件已收到的 chunk 索引
  final Map<String, int> _lastAckChunk = {}; // 追踪每个文件最后确认的 chunk 索引（用于批量确认）
  static const int _batchAckInterval = 20; // 默认每 20 个 chunk 发送一次批量确认
  static const int _largeChunkBatchAckInterval = 6; // 大 chunk 更频繁确认，保持双端进度更接近
  static const int _iosSingleWritePayloadSize =
      116; // 180B ATT 写入预算 - 64B NearLink 头
  static const int _androidPeripheralPayloadSize =
      NearLinkConstants.maxChunkSize * 2; // 880B，由原生通知层拆成多次发送
  static const Duration _transferCompleteAckTimeout = Duration(seconds: 5);
  static const Duration _androidPeripheralTransferCompleteRetryTimeout =
      Duration(seconds: 15);
  static const Duration _androidPeripheralTransferCompleteOverallTimeout =
      Duration(minutes: 3);

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
  static const _notifyThrottleDuration =
      Duration(milliseconds: 50); // 降低到 50ms 提高响应性
  int _pendingChunkUpdate = 0; // 待处理的 chunk 更新计数

  // Getters
  List<FileTransfer> get activeTransfers => _activeTransfers.values.toList();
  List<FileTransfer> get transferHistory => List.unmodifiable(_transferHistory);
  FileTransfer? get currentTransfer =>
      _activeTransfers.isNotEmpty ? _activeTransfers.values.first : null;

  int _batchAckIntervalFor(NearLinkPacket packet) {
    if (packet.payload.length >= NearLinkConstants.maxChunkSize) {
      return _largeChunkBatchAckInterval;
    }
    return _batchAckInterval;
  }

  ({bool isPeripheralMode, bool isTargetIOS, int chunkSize, int totalChunks})
      _buildSendPlan(int fileSize) {
    final isPeripheralMode = _bluetoothService.isPeripheralConnected;
    final isTargetIOS = _bluetoothService.isConnectedToIOSPeer;
    int chunkSize;
    if (isPeripheralMode && Platform.isIOS) {
      final centralMtu = _bluetoothService.connectedCentralMtu;
      final canUseLargePacket = centralMtu != null &&
          centralMtu >=
              NearLinkConstants.maxChunkSize + NearLinkConstants.headerSize;
      chunkSize = canUseLargePacket ? NearLinkConstants.maxChunkSize : 180;
    } else if (isPeripheralMode && Platform.isAndroid) {
      chunkSize = _androidPeripheralPayloadSize;
    } else if (isTargetIOS) {
      // Android 作为 Central 发给 iOS Peripheral 时，让编码后的 NearLink 包尽量落在一次 ATT 写里。
      chunkSize = _iosSingleWritePayloadSize;
    } else {
      chunkSize = NearLinkConstants.maxChunkSize;
    }
    final totalChunks = (fileSize / chunkSize).ceil();

    return (
      isPeripheralMode: isPeripheralMode,
      isTargetIOS: isTargetIOS,
      chunkSize: chunkSize,
      totalChunks: totalChunks,
    );
  }

  /// 初始化
  void initialize() {
    _bluetoothService.setPacketListener(_handlePacket);
  }

  /// 准备发送文件（可指定是否压缩图片）
  /// [compressImage] - 是否压缩图片文件，仅对图片有效
  Future<FileTransfer?> prepareFile(String filePath,
      {bool compressImage = false}) async {
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
        isOutgoing: true, // 标记为发送传输
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
  Future<FileTransfer?> prepareFileWithBytes(
      String fileName, Uint8List fileData,
      {bool compressImage = false}) async {
    try {
      // debugPrint(
      //     '[FileTransfer] prepareFileWithBytes: 文件=$fileName, 大小=${fileData.length} bytes');
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
        filePath: '', // 字节数据无路径
        fileSize: finalSize,
        mimeType: mimeType,
        totalChunks: totalChunks,
        status: TransferStatus.idle,
        startTime: DateTime.now(),
        isOutgoing: true, // 标记为发送传输
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
    final isConnected = _bluetoothService.isConnected ||
        _bluetoothService.isPeripheralConnected;

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

      final sendPlan = _buildSendPlan(fileData.length);
      final actualTotalChunks = sendPlan.totalChunks;

      if (transfer.totalChunks != actualTotalChunks) {
        _activeTransfers[fileId] = transfer.copyWith(
          totalChunks: actualTotalChunks,
        );
      }

      final fileChecksum = _calculateChecksum(Uint8List.fromList(fileData));
      final fileInfoPacket = NearLinkPacket.fileInfo(
        fileId: fileId,
        fileName: transfer.fileName,
        fileSize: transfer.fileSize,
        mimeType: transfer.mimeType,
        totalChunks: actualTotalChunks,
        fileChecksum: Uint8List.fromList(fileChecksum.codeUnits),
      );

      _updateTransfer(fileId, status: TransferStatus.transferring);
      final sendResult = await _bluetoothService.sendPacket(fileInfoPacket);
      if (!sendResult) {
        _updateTransfer(fileId,
            status: TransferStatus.failed, errorMessage: '发送文件信息失败');
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
        _updateTransfer(fileId,
            status: TransferStatus.failed, errorMessage: '对方未确认接收');
        return false;
      }

      // 开始发送数据块
      await _sendChunks(fileId, Uint8List.fromList(fileData), sendPlan);

      return true;
    } catch (e) {
      _updateTransfer(fileId,
          status: TransferStatus.failed, errorMessage: e.toString());
      return false;
    }
  }

  /// 发送数据块
  Future<void> _sendChunks(
    String fileId,
    Uint8List data,
    ({
      bool isPeripheralMode,
      bool isTargetIOS,
      int chunkSize,
      int totalChunks
    }) sendPlan,
  ) async {
    final isPeripheralMode = sendPlan.isPeripheralMode;
    final isTargetIOS = sendPlan.isTargetIOS;
    final effectiveChunkSize = sendPlan.chunkSize;
    final totalChunks = sendPlan.totalChunks;

    // debugPrint(
    //   '[FileTransfer] _sendChunks: effectiveChunkSize=$effectiveChunkSize, '
    //   'isPeripheralMode=$isPeripheralMode, isTargetIOS=$isTargetIOS, '
    //   'totalChunks=$totalChunks',
    // );

    // 只有 iOS 原生层实现了批量发送；Android 作为 Peripheral 走顺序发送。
    if (isPeripheralMode && Platform.isIOS) {
      await _sendChunksBatch(fileId, data, effectiveChunkSize, totalChunks);
    } else {
      await _sendChunksSequential(
          fileId, data, effectiveChunkSize, totalChunks, isTargetIOS);
    }
  }

  /// 批量发送数据块（用于 iOS 作为 Peripheral 向 Android 发送）
  Future<void> _sendChunksBatch(
    String fileId,
    Uint8List data,
    int chunkSize,
    int totalChunks,
  ) async {
    const int batchSize = 256; // 增大批次，减少 Flutter/iOS 往返

    for (int batchStart = 0;
        batchStart < totalChunks;
        batchStart += batchSize) {
      final batchEnd = (batchStart + batchSize < totalChunks)
          ? batchStart + batchSize
          : totalChunks;
      final packets = <Uint8List>[];

      // 构建一批数据包
      for (int i = batchStart; i < batchEnd; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, data.length);
        final chunk = data.sublist(start, end);

        final packet = NearLinkPacket.chunk(
          fileId: fileId,
          chunkIndex: i,
          totalChunks: totalChunks,
          data: Uint8List.fromList(chunk),
        );
        packets.add(packet.encode());
      }

      // 批量发送给原生层
      final success = await _bluetoothService.sendDataBatch(packets);
      if (!success) {
        _updateTransfer(fileId,
            status: TransferStatus.failed, errorMessage: '批量发送失败');
        return;
      }

      // 移除批次间延迟，最大化传输速度
      // 让原生层自己控制发送速率
    }

    await _finalizeOutgoingTransfer(fileId, data);
  }

  /// 顺序发送数据块（传统方式）
  Future<void> _sendChunksSequential(
    String fileId,
    Uint8List data,
    int chunkSize,
    int totalChunks,
    bool isTargetIOS,
  ) async {
    final shouldOptimisticallyAdvanceProgress =
        !(Platform.isAndroid && _bluetoothService.isPeripheralConnected);

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, data.length);
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
          _updateTransfer(fileId,
              status: TransferStatus.failed, errorMessage: '发送失败');
          return;
        }
      } catch (e) {
        _updateTransfer(fileId,
            status: TransferStatus.failed, errorMessage: e.toString());
        return;
      }

      // 更新发送进度
      if (shouldOptimisticallyAdvanceProgress &&
          (i % 5 == 0 || i == totalChunks - 1)) {
        _updateTransfer(
          fileId,
          currentChunk: i + 1,
          progress: (i + 1) / totalChunks,
        );
      }

      // 向 iOS 发送时添加极小延迟
      if (isTargetIOS && i < totalChunks - 1 && i % 5 == 4) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    await _finalizeOutgoingTransfer(fileId, data);
  }

  /// 发送完所有 chunk 后，发送 transferComplete 并等待对方确认
  Future<void> _finalizeOutgoingTransfer(String fileId, Uint8List data) async {
    final transfer = _activeTransfers[fileId];
    if (transfer == null) return;

    final isAndroidPeripheralSender =
        Platform.isAndroid && _bluetoothService.isPeripheralConnected;

    if (isAndroidPeripheralSender) {
      final queueDrained =
          await _bluetoothService.waitForPeripheralSendQueueDrained();
      if (!queueDrained) {
        _updateTransfer(
          fileId,
          status: TransferStatus.failed,
          errorMessage: _bluetoothService.errorMessage ?? '等待原生发送队列清空超时',
        );
        return;
      }
    }

    // 等待一小段时间确保最后一个 chunk 被对方接收
    // BLE 传输可能需要一些时间才能完全到达对方
    await Future.delayed(
      isAndroidPeripheralSender
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 300),
    );

    final completePacket = NearLinkPacket.transferComplete(
      fileId: fileId,
      fileChecksum: _calculateChecksum(data),
    );

    final ackReceived = await _waitForTransferCompleteAck(
      fileId: fileId,
      completePacket: completePacket,
      perAttemptTimeout: isAndroidPeripheralSender
          ? _androidPeripheralTransferCompleteRetryTimeout
          : _transferCompleteAckTimeout,
      overallTimeout: isAndroidPeripheralSender
          ? _androidPeripheralTransferCompleteOverallTimeout
          : _transferCompleteAckTimeout * 3,
    );

    _transferCompleteCompleter = null;

    final latestTransfer = _activeTransfers[fileId];
    if (latestTransfer == null ||
        latestTransfer.status == TransferStatus.completed) {
      return;
    }

    if (!ackReceived) {
      _updateTransfer(
        fileId,
        status: TransferStatus.failed,
        errorMessage: '等待对方完成确认超时',
      );
      return;
    }

    _markOutgoingTransferCompleted(fileId);
  }

  /// 处理接收到的数据包
  Future<void> _handlePacket(NearLinkPacket packet) async {
    // 只在非chunk包时打印，避免高频打印影响性能
    // if (packet.type != PacketType.chunk) {
    //   debugPrint(
    //       '[FileTransfer] _handlePacket: type=${packet.type}, fileId=${_shortFileId(packet.fileId)}...');
    // }
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
      case PacketType.batchAck:
        _handleBatchAck(packet);
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
    if (_transferCompleteCompleter != null &&
        !_transferCompleteCompleter!.isCompleted) {
      _transferCompleteCompleter!.complete(true);
    }

    final transfer = _activeTransfers[packet.fileId];
    if (transfer == null || !transfer.isOutgoing) return;

    _markOutgoingTransferCompleted(packet.fileId);
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
    _receivedChunks[packet.fileId] = {}; // 初始化 chunk 追踪集合

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

    // 更新进度（降低节流时间以提高响应性）
    _updateTransferThrottled(
      packet.fileId,
      currentChunk: packet.chunkIndex + 1,
      progress: (packet.chunkIndex + 1) / packet.totalChunks,
    );

    // 批量确认逻辑：每 _batchAckInterval 个 chunk 发送一次批量确认
    // 或者如果是最后一个 chunk，立即发送确认
    final lastAck = _lastAckChunk[packet.fileId] ?? -1;
    final ackInterval = _batchAckIntervalFor(packet);
    final shouldSendBatchAck = (packet.chunkIndex - lastAck) >= ackInterval;
    final isLastChunk = packet.chunkIndex == packet.totalChunks - 1;

    if (shouldSendBatchAck || isLastChunk) {
      _sendBatchAckAsync(packet.fileId, packet.chunkIndex);
      _lastAckChunk[packet.fileId] = packet.chunkIndex;
    }

    // 检查是否收到了所有 chunk，如果是则自动完成传输
    _tryAutoCompleteTransfer(packet.fileId, packet.totalChunks);
  }

  /// 异步发送批量确认，不阻塞主接收流程
  void _sendBatchAckAsync(String fileId, int lastChunkIndex) {
    // 使用 microtask 确保不阻塞当前执行流
    Future.microtask(() async {
      try {
        // 发送批量确认，告知发送方已收到直到 lastChunkIndex 的所有 chunk
        await _bluetoothService.sendPacket(NearLinkPacket.batchAck(
          fileId: fileId,
          lastChunkIndex: lastChunkIndex,
        ));
      } catch (e) {
        // 忽略发送错误，批量确认不是关键路径
        debugPrint('[FileTransfer] batchAck 发送失败: $e');
      }
    });
  }

  /// 检查是否收到所有 chunk
  bool _checkAllChunksReceived(String fileId, int totalChunks) {
    final receivedSet = _receivedChunks[fileId];
    if (receivedSet == null) return false;

    // 检查是否收到了所有 chunk
    return receivedSet.length >= totalChunks;
  }

  /// 尝试自动完成传输（当收到所有 chunk 但没收到 transferComplete 时）
  void _tryAutoCompleteTransfer(String fileId, int totalChunks) {
    if (!_checkAllChunksReceived(fileId, totalChunks)) return;

    final data = _receivedData[fileId];
    if (data == null) return;

    // 检查是否已经完成或正在完成中
    final transfer = _activeTransfers[fileId];
    if (transfer == null || transfer.status == TransferStatus.completed) return;

    // 防止重复触发
    _updateTransfer(fileId, status: TransferStatus.completed);

    // debugPrint('[NearLink] 已收到所有 $totalChunks 个 chunk，自动完成传输');

    // 立即发送完成确认（不阻塞）
    _bluetoothService
        .sendPacket(NearLinkPacket(
      type: PacketType.transferCompleteAck,
      fileId: fileId,
      chunkIndex: 0,
      totalChunks: 0,
      payloadSize: 0,
      checksum: '',
      payload: Uint8List(0),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ))
        .catchError((e) {
      // debugPrint('[NearLink] 自动完成确认发送失败: $e');
      return false;
    });

    // 在后台保存文件
    Future.microtask(() async {
      await _saveFile(fileId, Uint8List.fromList(data));
    });

    // 延迟清理
    _cleanup(fileId);
  }

  /// 处理块确认
  void _handleChunkAck(NearLinkPacket packet) {
    // 发送方收到确认，更新已确认的块计数
    final transfer = _activeTransfers[packet.fileId];
    if (transfer == null) return;
    if (transfer.status != TransferStatus.transferring) return;

    final confirmedChunk = packet.chunkIndex + 1;
    final totalChunks = transfer.totalChunks;

    // 计算进度（已确认的块 / 总块数）
    final progress = totalChunks > 0 ? confirmedChunk / totalChunks : 0.0;

    // 只在进度增加时才更新，避免乱序的 chunkAck 导致进度回退
    if (confirmedChunk > transfer.currentChunk) {
      _updateTransfer(
        packet.fileId,
        currentChunk: confirmedChunk,
        progress: progress,
      );
    }
  }

  /// 处理批量确认
  /// 批量确认表示从 lastChunkIndex 之前的所有 chunk 都已成功接收
  void _handleBatchAck(NearLinkPacket packet) {
    // 发送方收到批量确认，更新已确认的块计数
    final transfer = _activeTransfers[packet.fileId];
    if (transfer == null) return;
    if (transfer.status != TransferStatus.transferring) return;

    // batchAck 的 chunkIndex 字段存储的是 lastChunkIndex
    final confirmedChunk = packet.chunkIndex + 1;
    final totalChunks = transfer.totalChunks;

    // 计算进度（已确认的块 / 总块数）
    final progress = totalChunks > 0 ? confirmedChunk / totalChunks : 0.0;

    // 只在进度增加时才更新
    if (confirmedChunk > transfer.currentChunk) {
      _updateTransfer(
        packet.fileId,
        currentChunk: confirmedChunk,
        progress: progress,
      );
      // debugPrint(
      //     '[FileTransfer] 批量确认: fileId=${_shortFileId(packet.fileId)}..., 确认到 chunk ${packet.chunkIndex}, 进度 ${(progress * 100).toStringAsFixed(1)}%');
    }
  }

  /// 处理传输完成
  Future<void> _handleTransferComplete(NearLinkPacket packet) async {
    final data = _receivedData[packet.fileId];
    if (data == null) {
      // debugPrint(
      //     '[FileTransfer] _handleTransferComplete: data is null for fileId=${_shortFileId(packet.fileId)}...');
      return;
    }

    // debugPrint(
    //     '[FileTransfer] _handleTransferComplete: 开始处理，fileId=${_shortFileId(packet.fileId)}..., dataSize=${data.length}');

    // 立即发送完成确认（不等待文件保存）
    // 这样可以确保发送方尽快收到确认，避免超时
    try {
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
      // debugPrint('[FileTransfer] _handleTransferComplete: 完成确认已发送');
    } catch (e) {
      // debugPrint('[FileTransfer] _handleTransferComplete: 发送确认失败: $e');
      // 即使发送确认失败也继续保存文件
    }

    // 先更新状态为已完成，让 UI 可以响应
    _updateTransfer(packet.fileId, status: TransferStatus.completed);
    // debugPrint('[FileTransfer] _handleTransferComplete: 状态已更新为 completed');

    // 在后台保存文件（不阻塞 UI）
    Future.microtask(() async {
      // debugPrint('[FileTransfer] _handleTransferComplete: 开始在后台保存文件');
      await _saveFile(packet.fileId, Uint8List.fromList(data));
      // if (savePath != null) {
      //   debugPrint('[FileTransfer] _handleTransferComplete: 文件保存成功: $savePath');
      // } else {
      //   debugPrint('[FileTransfer] _handleTransferComplete: 文件保存失败');
      // }
    });

    // 延迟清理，给 UI 时间检测完成状态
    _cleanup(packet.fileId);
    // debugPrint('[FileTransfer] _handleTransferComplete: 处理完成');
  }

  /// 处理取消
  void _handleCancel(NearLinkPacket packet) {
    if (packet.fileId.isEmpty) {
      _bluetoothService.handleRemoteDisconnectSignal();
      return;
    }

    _updateTransfer(packet.fileId, status: TransferStatus.cancelled);
    _cleanup(packet.fileId);
  }

  /// 保存接收到的文件
  /// Android: /storage/emulated/0/NearLink/ (储存卡根目录)
  /// iOS: 应用 Documents/NearLink/ (可通过 Finder 访问)
  Future<String?> _saveFile(String fileId, Uint8List data) async {
    final transfer = _activeTransfers[fileId];
    if (transfer == null) return null;

    try {
      // 根据平台选择保存路径
      String directoryPath;
      if (Platform.isAndroid) {
        // Android: 检查并请求存储权限
        await _requestStoragePermission();
        // 保存到储存卡根目录的 NearLink 文件夹
        directoryPath = '/storage/emulated/0/NearLink';
      } else {
        // iOS: 保存到应用 Documents 目录（不需要额外权限）
        final appDir = await getApplicationDocumentsDirectory();
        directoryPath = '${appDir.path}/NearLink';
      }

      // 使用原始文件名，但清理不安全字符
      final safeFileName = _sanitizeFileName(transfer.fileName);
      final savePath = '$directoryPath/$safeFileName';

      // 创建目录（使用同步方式避免 async 延迟）
      final saveDir = Directory(directoryPath);
      if (!saveDir.existsSync()) {
        await saveDir.create(recursive: true);
      }

      // 写入文件（使用 compute 在后台 isolate 执行大文件写入）
      if (data.length > 1024 * 1024) {
        // 大于 1MB 的文件使用后台写入
        await _writeFileInBackground(savePath, data);
      } else {
        // 小文件直接写入
        final file = File(savePath);
        await file.writeAsBytes(data, flush: true);
      }

      _fileSavedController.add(savePath);
      debugPrint('[FileTransfer] 文件保存成功: $savePath');
      return savePath;
    } catch (e) {
      debugPrint('[FileTransfer] 文件保存失败: $e');
      return null;
    }
  }

  /// 在后台 isolate 写入大文件
  Future<void> _writeFileInBackground(String path, Uint8List data) async {
    // 对于大文件，使用 synchronous 操作避免 event loop 阻塞
    // 注意：这里不使用 compute 是因为 Dart 单线程模型中 compute 也有序列化开销
    // 对于 >1MB 的文件，分段写入
    const chunkSize = 256 * 1024; // 256KB chunks
    final file = File(path).openSync(mode: FileMode.write);
    try {
      for (var offset = 0; offset < data.length; offset += chunkSize) {
        final end = (offset + chunkSize < data.length)
            ? offset + chunkSize
            : data.length;
        file.writeFromSync(data, offset, end);
        // 每写入一段，让出时间片
        if (end < data.length) {
          await Future.delayed(Duration.zero);
        }
      }
    } finally {
      file.closeSync();
    }
  }

  /// 清理文件名中的不安全字符
  String _sanitizeFileName(String fileName) {
    // 移除或替换文件系统不安全的字符
    final sanitized = fileName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_') // Windows 非法字符
        .replaceAll(RegExp(r'\s+'), ' ') // 多个空格合并
        .trim();
    // 限制长度
    if (sanitized.length > 200) {
      final ext = _getFileExtension(sanitized);
      return sanitized.substring(0, 200 - ext.length) + ext;
    }
    return sanitized;
  }

  /// 获取文件扩展名
  String _getFileExtension(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot > 0 && lastDot < fileName.length - 1) {
      return fileName.substring(lastDot);
    }
    return '';
  }

  /// 请求存储权限（仅 Android 需要）
  Future<void> _requestStoragePermission() async {
    // iOS 不需要额外权限来写入应用沙盒
    if (Platform.isIOS) {
      return;
    }

    // Android: 首先请求基本存储权限
    if (!await Permission.storage.isGranted) {
      await Permission.storage.request();
    }

    // Android 11+ (API 30+) 需要 MANAGE_EXTERNAL_STORAGE 才能访问根目录
    if (Platform.isAndroid) {
      try {
        if (!await Permission.manageExternalStorage.isGranted) {
          final status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            debugPrint('[FileTransfer] 未获得管理外部存储权限，可能无法保存到根目录');
          }
        }
      } catch (e) {
        debugPrint('[FileTransfer] 请求 MANAGE_EXTERNAL_STORAGE 失败: $e');
      }
    }
  }

  /// 取消传输
  Future<void> cancelTransfer(String fileId) async {
    try {
      // 立即更新状态，让 UI 响应
      _updateTransfer(fileId, status: TransferStatus.cancelled);

      // 立即清理，避免阻塞
      _immediateCleanup(fileId);

      // 异步发送取消包（不阻塞 UI）
      _bluetoothService
          .sendPacket(NearLinkPacket.cancel(fileId: fileId))
          .catchError((e) {
        debugPrint('[FileTransfer] 取消包发送失败: $e');
        return false;
      });
    } catch (e) {
      debugPrint('[FileTransfer] cancelTransfer 异常: $e');
    }
  }

  /// 立即清理（用于取消操作）
  void _immediateCleanup(String fileId) {
    final completedTransfer = _activeTransfers[fileId];
    _receivedData.remove(fileId);
    _receivedChunks.remove(fileId);
    _lastAckChunk.remove(fileId);

    if (completedTransfer != null) {
      _transferHistory.insert(0, completedTransfer);
    }

    // 立即移除传输对象
    _activeTransfers.remove(fileId);
    _notifyListenersImmediate();
  }

  /// 清理传输数据
  void _cleanup(String fileId) {
    final completedTransfer = _activeTransfers[fileId];
    _receivedData.remove(fileId);
    _receivedChunks.remove(fileId); // 清理 chunk 追踪
    _lastAckChunk.remove(fileId); // 清理批量确认追踪

    if (completedTransfer != null) {
      _transferHistory.insert(0, completedTransfer);
    }

    // 延迟移除传输对象，给 UI 时间检测 completed 状态并自动返回
    // 使用 microtask 避免阻塞，同时确保延迟执行
    Future.delayed(const Duration(milliseconds: 800), () {
      _activeTransfers.remove(fileId);
      // 使用立即刷新确保 UI 立即更新
      _notifyListenersImmediate();
    });
  }

  Future<bool> _waitForTransferCompleteAck({
    required String fileId,
    required NearLinkPacket completePacket,
    required Duration perAttemptTimeout,
    required Duration overallTimeout,
  }) async {
    final startTime = DateTime.now();

    while (DateTime.now().difference(startTime) < overallTimeout) {
      _transferCompleteCompleter = Completer<bool>();

      final sent = await _bluetoothService.sendPacket(completePacket);
      if (!sent) {
        final transfer = _activeTransfers[fileId];
        if (transfer == null ||
            transfer.status == TransferStatus.failed ||
            transfer.status == TransferStatus.cancelled) {
          return false;
        }
      }

      final ackReceived = await _transferCompleteCompleter!.future.timeout(
        perAttemptTimeout,
        onTimeout: () => false,
      );

      final latestTransfer = _activeTransfers[fileId];
      if (ackReceived ||
          latestTransfer == null ||
          latestTransfer.status == TransferStatus.completed) {
        return true;
      }

      if (latestTransfer.status == TransferStatus.failed ||
          latestTransfer.status == TransferStatus.cancelled) {
        return false;
      }

      // debugPrint(
      //   '[FileTransfer] 等待完成确认中: '
      //   'progress=${(latestTransfer.progress * 100).toStringAsFixed(1)}%',
      // );

      await Future.delayed(const Duration(milliseconds: 500));
    }

    // debugPrint('[FileTransfer] 等待完成确认超时');
    return false;
  }

  void _markOutgoingTransferCompleted(String fileId) {
    final transfer = _activeTransfers[fileId];
    if (transfer == null || transfer.status == TransferStatus.completed) {
      return;
    }

    _updateTransfer(
      fileId,
      status: TransferStatus.completed,
      currentChunk: transfer.totalChunks,
      progress: 1.0,
    );
    _cleanup(fileId);
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

    // 状态变化立即通知，进度变化节流
    final now = DateTime.now();
    if (status != null ||
        _lastNotifyTime == null ||
        now.difference(_lastNotifyTime!) >= _notifyThrottleDuration) {
      _lastNotifyTime = now;
      _pendingChunkUpdate = 0;
      notifyListeners();
    } else {
      _pendingChunkUpdate++;
      // 累积一定数量未显示的更新时强制刷新
      if (_pendingChunkUpdate >= 10) {
        _lastNotifyTime = now;
        _pendingChunkUpdate = 0;
        notifyListeners();
      }
    }
  }

  /// 节流的进度更新（用于高频 chunk 接收）
  void _updateTransferThrottled(
    String fileId, {
    int? currentChunk,
    double? progress,
  }) {
    final transfer = _activeTransfers[fileId];
    if (transfer == null) return;

    _activeTransfers[fileId] = transfer.copyWith(
      currentChunk: currentChunk,
      progress: progress,
    );

    final now = DateTime.now();
    if (_lastNotifyTime == null ||
        now.difference(_lastNotifyTime!) >= _notifyThrottleDuration) {
      _lastNotifyTime = now;
      _pendingChunkUpdate = 0;
      notifyListeners();
    } else {
      _pendingChunkUpdate++;
      if (_pendingChunkUpdate >= 20) {
        _lastNotifyTime = now;
        _pendingChunkUpdate = 0;
        notifyListeners();
      }
    }
  }

  /// 立即刷新 UI（用于关键状态变化）
  void _notifyListenersImmediate() {
    _lastNotifyTime = DateTime.now();
    notifyListeners();
  }

  /// 压缩图片
  /// 目标：压缩到原大小的 50% 或最大 200KB，取较小值
  Future<Uint8List?> _compressImage(
      Uint8List imageData, String fileName) async {
    try {
      // 获取临时目录用于存储压缩结果
      final tempDir = await getTemporaryDirectory();
      final targetPath =
          '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // 确定目标质量：从 80 开始，根据文件大小调整
      int quality = 80;

      // 压缩循环，逐步降低质量直到文件大小合适
      while (quality > 20) {
        final result = await FlutterImageCompress.compressWithList(
          imageData,
          quality: quality,
          format: CompressFormat.jpeg,
          minWidth: 1920, // 最大宽度
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
