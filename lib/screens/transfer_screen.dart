import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/nearlink_provider.dart';
import '../models/nearlink_models.dart';
import '../widgets/nearlink_widgets.dart';

/// 传输页面
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  Timer? _progressTimer;
  TransferStatus? _lastStatus;
  bool _lastConnectionState = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<NearLinkProvider>();
      _lastStatus = provider.currentTransfer?.status;
      _lastConnectionState = provider.isConnected || provider.isPeripheralConnected;
      _startProgressMonitoring();
      
      // 如果没有正在进行的传输任务，自动开始发送选中的文件
      if (provider.currentTransfer == null) {
        _startSending();
      }
    });
  }
  
  /// 开始发送文件
  void _startSending() async {
    try {
      final provider = context.read<NearLinkProvider>();
      final scaffoldMessenger = ScaffoldMessenger.of(context);
      
      final transfer = await provider.sendFile();
      
      if (transfer == null && mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('发送失败：无法准备文件或未连接'),
            backgroundColor: NearLinkColors.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送异常: $e'),
            backgroundColor: NearLinkColors.error,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  /// 监听传输状态变化和连接状态
  void _startProgressMonitoring() {
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final provider = context.read<NearLinkProvider>();
      
      // 检测连接断开
      final isConnected = provider.isConnected || provider.isPeripheralConnected;
      if (_lastConnectionState && !isConnected) {
        // 连接刚刚断开
        _lastConnectionState = false;
        _onConnectionLost();
        return;
      }
      _lastConnectionState = isConnected;
      
      if (provider.currentTransfer != null) {
        final transfer = provider.currentTransfer!;
        
        // 检测传输完成
        if (_lastStatus != TransferStatus.completed && 
            transfer.status == TransferStatus.completed) {
          _onTransferComplete(transfer);
        }
        
        // 检测传输失败
        if (_lastStatus != TransferStatus.failed && 
            transfer.status == TransferStatus.failed) {
          _onTransferFailed(transfer);
        }
        
        _lastStatus = transfer.status;
      }
    });
  }
  
  /// 连接断开时的处理
  void _onConnectionLost() {
    if (!mounted) return;
    
    // 显示断开提示
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('连接已断开，正在返回...'),
        backgroundColor: NearLinkColors.error,
        duration: Duration(seconds: 2),
      ),
    );
    
    // 取消所有活跃传输
    final provider = context.read<NearLinkProvider>();
    for (final transfer in provider.activeTransfers) {
      if (transfer.status == TransferStatus.transferring) {
        provider.cancelTransfer(transfer.fileId);
      }
    }
    
    // 延迟返回首页
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _onTransferComplete(FileTransfer transfer) async {
    if (!mounted) return;
    
    // 显示成功提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${transfer.filePath.isNotEmpty ? "发送" : "接收"}完成: ${transfer.fileName}'),
        backgroundColor: NearLinkColors.success,
        duration: const Duration(seconds: 1),
      ),
    );
    
    // 延迟一点返回主页，让用户看到提示
    await Future.delayed(const Duration(milliseconds: 800));
    
    if (!mounted) return;
    
    // 返回主页
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _onTransferFailed(FileTransfer transfer) {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('传输失败: ${transfer.errorMessage ?? "未知错误"}'),
        backgroundColor: NearLinkColors.error,
        action: SnackBarAction(
          label: '重试',
          textColor: Colors.white,
          onPressed: () {
            // 重试逻辑
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件传输'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _confirmExit(context),
        ),
        actions: [
          if (context.watch<NearLinkProvider>().isIOS)
            IconButton(
              icon: const Icon(Icons.ios_share),
              onPressed: () => _useAirDrop(context),
              tooltip: '使用 AirDrop',
            ),
        ],
      ),
      body: Selector<NearLinkProvider, bool>(
        selector: (_, provider) => provider.isConnected || provider.isPeripheralConnected,
        builder: (context, isConnected, child) {
          if (!isConnected) {
            // 连接断开时显示全屏提示，自动返回按钮
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.link_off,
                    size: 80,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '连接已断开',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '对方设备已断开连接',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 30),
                  ElevatedButton.icon(
                    onPressed: () {
                      // 取消所有活跃传输
                      final provider = context.read<NearLinkProvider>();
                      for (final transfer in provider.activeTransfers) {
                        if (transfer.status == TransferStatus.transferring) {
                          provider.cancelTransfer(transfer.fileId);
                        }
                      }
                      // 返回首页
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    icon: const Icon(Icons.home),
                    label: const Text('返回首页'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 30,
                        vertical: 15,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          
          // 连接正常时显示传输界面
          return Column(
            children: [
              // 连接信息
              _buildConnectionInfoStatic(context),
              // 传输状态
              Expanded(
                child: _buildTransferStatusOptimized(context),
              ),
              // 底部操作
              _buildBottomActionsOptimized(context),
            ],
          );
        },
      ),
    );
  }

  /// 连接信息静态版本（连接状态变化时才重建）
  Widget _buildConnectionInfoStatic(BuildContext context) {
    return Selector<NearLinkProvider, bool>(
      selector: (_, provider) => provider.isConnected || provider.isPeripheralConnected,
      builder: (context, isConnected, child) {
        if (!isConnected) {
          return Container(
            padding: const EdgeInsets.all(20),
            child: const EmptyState(
              icon: Icons.link_off,
              title: '连接已断开',
              description: '请返回重新连接设备',
            ),
          );
        }
        // 连接信息本身也需要更新设备名称
        return Selector<NearLinkProvider, NearLinkProvider>(
          selector: (_, provider) => provider,
          builder: (context, provider, child) {
            return _buildConnectionInfo(provider);
          },
        );
      },
    );
  }

  /// 传输状态优化版本（只让进度相关的 widget 监听变化）
  Widget _buildTransferStatusOptimized(BuildContext context) {
    return Selector<NearLinkProvider, FileTransfer?>(
      selector: (_, provider) => provider.currentTransfer,
      builder: (context, transfer, child) {
        if (transfer == null) {
          return const EmptyState(
            icon: Icons.file_copy_outlined,
            title: '暂无传输任务',
            description: '请选择要发送的文件',
          );
        }
        // 只让进度相关的 widget 监听 transfer 对象的变化
        return _TransferProgressWidget(
          key: ValueKey(transfer.fileId),
          transfer: transfer,
        );
      },
    );
  }

  /// 底部操作优化版本（只监听状态和传输对象）
  Widget _buildBottomActionsOptimized(BuildContext context) {
    return Selector<NearLinkProvider, ({FileTransfer? transfer, bool isTransferring})>(
      selector: (_, provider) => (
        transfer: provider.currentTransfer,
        isTransferring: provider.currentTransfer?.status == TransferStatus.transferring,
      ),
      builder: (context, data, child) {
        return _buildBottomActions(context, data.transfer);
      },
    );
  }

  Widget _buildConnectionInfo(NearLinkProvider provider) {
    final remoteDevice = provider.connectedRemoteDevice;
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            NearLinkColors.success.withAlpha((0.15 * 255).toInt()),
            NearLinkColors.success.withAlpha((0.05 * 255).toInt()),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: NearLinkColors.success.withAlpha((0.2 * 255).toInt()),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.phone_android,
              color: NearLinkColors.success,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: NearLinkColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '已连接设备',
                      style: TextStyle(
                        fontSize: 12,
                        color: NearLinkColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  remoteDevice?.name.isNotEmpty == true 
                      ? remoteDevice!.name 
                      : provider.connectedDevice?.platformName 
                          ?? provider.lastIncomingDeviceName  // iOS 作为 Peripheral 被连接时显示对方名称
                          ?? '未知设备',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (remoteDevice != null)
                  Text(
                    '信号: ${remoteDevice.rssi} dBm',
                    style: const TextStyle(
                      fontSize: 12,
                      color: NearLinkColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: NearLinkColors.success.withAlpha((0.2 * 255).toInt()),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bluetooth, color: NearLinkColors.success, size: 16),
                SizedBox(width: 4),
                Text(
                  '蓝牙',
                  style: TextStyle(
                    color: NearLinkColors.success,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions(BuildContext context, FileTransfer? transfer) {
    final provider = context.read<NearLinkProvider>();
    
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (transfer != null &&
              transfer.status == TransferStatus.transferring)
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _cancelTransfer(context, provider, transfer),
                icon: const Icon(Icons.cancel),
                label: const Text('取消传输'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NearLinkColors.error,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            )
          else if (transfer != null && transfer.status == TransferStatus.completed)
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.check_circle),
                label: const Text('完成'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NearLinkColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            )
          else
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NearLinkColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _cancelTransfer(
      BuildContext context, NearLinkProvider provider, FileTransfer transfer) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消传输'),
        content: const Text('确定要取消当前传输吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('继续传输'),
          ),
          ElevatedButton(
            onPressed: () {
              provider.cancelTransfer(transfer.fileId);
              Navigator.pop(dialogContext);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: NearLinkColors.error,
            ),
            child: const Text('取消传输'),
          ),
        ],
      ),
    );
  }

  void _confirmExit(BuildContext context) {
    final provider = context.read<NearLinkProvider>();
    final transfer = provider.currentTransfer;

    if (transfer != null && transfer.status == TransferStatus.transferring) {
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('退出传输'),
          content: const Text('当前正在传输中，确定要退出吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('继续传输'),
            ),
            ElevatedButton(
              onPressed: () {
                provider.cancelTransfer(transfer.fileId);
                Navigator.pop(dialogContext);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: NearLinkColors.error,
              ),
              child: const Text('退出'),
            ),
          ],
        ),
      );
    } else {
      Navigator.pop(context);
    }
  }

  void _useAirDrop(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在打开 AirDrop...'),
      ),
    );
  }

  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('document')) {
      return Icons.description;
    }
    if (mimeType.contains('sheet') || mimeType.contains('excel')) {
      return Icons.table_chart;
    }
    return Icons.insert_drive_file;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 独立的进度显示 widget，只在 transfer 变化时重建
class _TransferProgressWidget extends StatelessWidget {
  final FileTransfer transfer;

  const _TransferProgressWidget({
    super.key,
    required this.transfer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // 文件信息卡片
          Expanded(
            child: Card(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // 文件图标和进度圆环
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 120,
                            height: 120,
                            child: CircularProgressIndicator(
                              value: transfer.progress,
                              strokeWidth: 8,
                              backgroundColor: NearLinkColors.primary.withAlpha((0.15 * 255).toInt()),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _getStatusColor(transfer.status),
                              ),
                            ),
                          ),
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              color: _getStatusColor(transfer.status).withAlpha((0.1 * 255).toInt()),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _getStatusIcon(transfer.status, transfer.mimeType),
                              size: 48,
                              color: _getStatusColor(transfer.status),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // 百分比
                      Text(
                        '${(transfer.progress * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: _getStatusColor(transfer.status),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // 状态文字
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: _getStatusColor(transfer.status).withAlpha((0.1 * 255).toInt()),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _getStatusText(transfer.status),
                          style: TextStyle(
                            color: _getStatusColor(transfer.status),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 文件名
                      Text(
                        transfer.fileName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      // 文件大小
                      Text(
                        _formatFileSize(transfer.fileSize),
                        style: const TextStyle(
                          fontSize: 14,
                          color: NearLinkColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 进度详情
                      _buildProgressDetails(transfer),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 预计剩余时间
          if (transfer.status == TransferStatus.transferring)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        color: NearLinkColors.textSecondary,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '预计剩余: ${_estimateRemainingTime(transfer)}',
                        style: const TextStyle(
                          fontSize: 14,
                          color: NearLinkColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressDetails(FileTransfer transfer) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NearLinkColors.primary.withAlpha((0.05 * 255).toInt()),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildDetailItem(
            Icons.storage,
            '已传输',
            _formatFileSize((transfer.fileSize * transfer.progress).toInt()),
          ),
          Container(
            width: 1,
            height: 30,
            color: NearLinkColors.textSecondary.withAlpha((0.2 * 255).toInt()),
          ),
          _buildDetailItem(
            Icons.layers,
            '数据包',
            '${transfer.currentChunk} / ${transfer.totalChunks}',
          ),
          Container(
            width: 1,
            height: 30,
            color: NearLinkColors.textSecondary.withAlpha((0.2 * 255).toInt()),
          ),
          _buildDetailItem(
            Icons.speed,
            '速度',
            _calculateSpeed(transfer),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 18, color: NearLinkColors.textSecondary),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: NearLinkColors.textSecondary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _estimateRemainingTime(FileTransfer transfer) {
    if (transfer.progress <= 0) return '--';
    final elapsed = DateTime.now().difference(transfer.startTime);
    final total = elapsed.inMilliseconds / transfer.progress;
    final remaining = total - elapsed.inMilliseconds;
    if (remaining < 1000) return '< 1 秒';
    if (remaining < 60000) return '${(remaining / 1000).ceil()} 秒';
    return '${(remaining / 60000).ceil()} 分钟';
  }

  String _calculateSpeed(FileTransfer transfer) {
    if (transfer.progress <= 0) return '-- KB/s';
    final elapsed = DateTime.now().difference(transfer.startTime);
    if (elapsed.inSeconds == 0) return '-- KB/s';
    final bytesPerSecond = (transfer.fileSize * transfer.progress) / elapsed.inSeconds;
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  IconData _getStatusIcon(TransferStatus status, String mimeType) {
    switch (status) {
      case TransferStatus.completed:
        return Icons.check_circle;
      case TransferStatus.failed:
        return Icons.error;
      case TransferStatus.cancelled:
        return Icons.cancel;
      default:
        if (mimeType.startsWith('image/')) return Icons.image;
        if (mimeType.startsWith('video/')) return Icons.video_file;
        if (mimeType.startsWith('audio/')) return Icons.audio_file;
        if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
        if (mimeType.contains('word') || mimeType.contains('document')) {
          return Icons.description;
        }
        if (mimeType.contains('sheet') || mimeType.contains('excel')) {
          return Icons.table_chart;
        }
        return Icons.insert_drive_file;
    }
  }

  String _getStatusText(TransferStatus status) {
    switch (status) {
      case TransferStatus.idle:
        return '等待开始';
      case TransferStatus.connecting:
        return '连接中...';
      case TransferStatus.handshaking:
        return '握手...';
      case TransferStatus.transferring:
        return '传输中...';
      case TransferStatus.completed:
        return '传输完成';
      case TransferStatus.failed:
        return '传输失败';
      case TransferStatus.cancelled:
        return '已取消';
    }
  }

  Color _getStatusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.transferring:
        return NearLinkColors.primary;
      case TransferStatus.completed:
        return NearLinkColors.success;
      case TransferStatus.failed:
      case TransferStatus.cancelled:
        return NearLinkColors.error;
      default:
        return NearLinkColors.textSecondary;
    }
  }
}
