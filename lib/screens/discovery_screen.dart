import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/nearlink_provider.dart';
import '../models/nearlink_models.dart';
import '../widgets/nearlink_widgets.dart';
import '../bluetooth/nearlink_bluetooth_service.dart';
import 'transfer_screen.dart';

/// 设备发现页面
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  bool _showOnlyPhones = true;  // 默认只显示手机设备
  StreamSubscription<ConnectionSuccessEvent>? _incomingConnectionSubscription;
  Timer? _advertiseRefreshTimer;  // 广播状态刷新定时器
  StreamSubscription<List<FileTransfer>>? _transferSubscription; // 监听传输任务
  StreamSubscription<String>? _fileSavedSubscription; // 监听文件保存完成
  
  @override
  void initState() {
    super.initState();
    // 监听被动连接事件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<NearLinkProvider>();
      
      _incomingConnectionSubscription = provider.onIncomingConnection.listen(
        (event) {
          // 被动连接，静默处理，不显示任何提示
        },
      );
      
      // 监听接收到的文件传输（作为接收方）
      _transferSubscription = provider.onTransferReceived.listen(
        (transfers) {
          _navigateToTransferScreen();
        },
      );
      
      // 监听文件保存完成
      _fileSavedSubscription = provider.onFileSaved.listen(
        (savePath) => _showFileSavedToast(savePath),
      );
    });
    
    // 启动广播状态刷新定时器
    _startAdvertiseRefreshTimer();
  }

  @override
  void dispose() {
    _incomingConnectionSubscription?.cancel();
    _advertiseRefreshTimer?.cancel();
    _transferSubscription?.cancel();
    _fileSavedSubscription?.cancel();
    super.dispose();
  }
  
  /// 显示文件保存完成 Toast
  void _showFileSavedToast(String savePath) {
    if (!mounted) return;
    
    // 统一显示根目录 NearLink
    final directory = 'NearLink (根目录)';
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.download_done, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '文件已保存',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '保存位置: $directory',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: NearLinkColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.all(16),
      ),
    );
  }
  
  /// 跳转到传输页面（接收文件时）
  void _navigateToTransferScreen() {
    if (!mounted) return;
    
    // 检查是否已经在 TransferScreen
    final route = ModalRoute.of(context);
    if (route?.settings.name == '/transfer') {
      return; // 已经在传输页面
    }
    
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const TransferScreen(),
        settings: const RouteSettings(name: '/transfer'),
      ),
    );
  }
  
  /// 启动广播状态刷新定时器
  void _startAdvertiseRefreshTimer() {
    _advertiseRefreshTimer?.cancel();
    _advertiseRefreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        final provider = context.read<NearLinkProvider>();
        // 如果正在广播，刷新 UI 以更新倒计时
        if (provider.isAdvertising && mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bluetooth, color: NearLinkColors.primary),
            SizedBox(width: 8),
            Text('NearLink'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showSettings(context),
          ),
        ],
      ),
      body: Consumer<NearLinkProvider>(
        builder: (context, provider, child) {
          return Column(
            children: [
              // 连接状态区域
              _buildConnectionStatus(provider),
              // 设备列表
              Expanded(
                child: _buildDeviceList(provider),
              ),
              // 底部操作区
              _buildActionBar(context, provider),
            ],
          );
        },
      ),
    );
  }

  Widget _buildConnectionStatus(NearLinkProvider provider) {
    final state = provider.connectionState;

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          if (state == NearLinkConnectionState.scanning)
            const BluetoothSearchingAnimation(size: 100)
          else if (state == NearLinkConnectionState.connecting)
            const CircularProgressIndicator()
          else if (state == NearLinkConnectionState.connected)
            _buildConnectedStatus(provider)
          else if (provider.isPeripheralConnected)
            _buildPeripheralConnectedStatus(provider)  // iOS 被连接状态
          else
            _buildIdleStatus(),
        ],
      ),
    );
  }
  
  /// 构建 iOS 作为 Peripheral 被连接的状态显示
  Widget _buildPeripheralConnectedStatus(NearLinkProvider provider) {
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: NearLinkColors.success.withAlpha((0.1 * 255).toInt()),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.bluetooth_connected,
            size: 60,
            color: NearLinkColors.success,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '设备已连接',
          style: TextStyle(
            fontSize: 16,
            color: NearLinkColors.success,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (provider.lastIncomingDeviceName != null)
          Text(
            provider.lastIncomingDeviceName!,
            style: const TextStyle(
              fontSize: 14,
              color: NearLinkColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: NearLinkColors.primary.withAlpha((0.1 * 255).toInt()),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.upload_file, size: 16, color: NearLinkColors.primary),
              SizedBox(width: 4),
              Text(
                '可以发送文件',
                style: TextStyle(
                  fontSize: 12,
                  color: NearLinkColors.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIdleStatus() {
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: NearLinkColors.primary.withAlpha((0.1 * 255).toInt()),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.bluetooth,
            size: 60,
            color: NearLinkColors.primary,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '点击下方按钮开始扫描',
          style: TextStyle(
            fontSize: 16,
            color: NearLinkColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '确保对方设备已打开 NearLink',
          style: TextStyle(
            fontSize: 13,
            color: NearLinkColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedStatus(NearLinkProvider provider) {
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: NearLinkColors.success.withAlpha((0.1 * 255).toInt()),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_circle,
            size: 60,
            color: NearLinkColors.success,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '已连接',
          style: TextStyle(
            fontSize: 16,
            color: NearLinkColors.success,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (provider.connectedDevice != null)
          Text(
            provider.connectedDevice!.platformName,
            style: const TextStyle(
              fontSize: 14,
              color: NearLinkColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _buildDeviceList(NearLinkProvider provider) {
    if (provider.connectionState == NearLinkConnectionState.scanning) {
      return Column(
        children: [
          const Expanded(
            child: EmptyState(
              icon: Icons.bluetooth_searching,
              title: '正在搜索附近设备...',
              description: '请确保对方的 NearLink 已打开',
            ),
          ),
          _buildFilterBar(provider),
        ],
      );
    }

    // 过滤设备列表
    final devices = _showOnlyPhones 
        ? provider.discoveredDevices.where((d) => d.isPossibleNearLinkDevice).toList()
        : provider.discoveredDevices;

    // 按信号强度排序
    devices.sort((a, b) => b.rssi.compareTo(a.rssi));

    if (devices.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: EmptyState(
              icon: _showOnlyPhones ? Icons.filter_alt_off : Icons.bluetooth_disabled,
              title: _showOnlyPhones ? '未发现手机设备' : '未发现附近设备',
              description: _showOnlyPhones 
                  ? '试试关闭过滤查看所有设备'
                  : '请确保对方的 NearLink 已打开，并保持蓝牙开启',
            ),
          ),
          _buildFilterBar(provider),
        ],
      );
    }

    return Column(
      children: [
        // NearLink 优先设备
        if (_showOnlyPhones && devices.any((d) => d.isPossibleNearLinkDevice)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.phone_android, size: 16, color: NearLinkColors.primary),
                const SizedBox(width: 4),
                Text(
                  '可能的 NearLink 设备 (${devices.where((d) => d.isPossibleNearLinkDevice).length})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: NearLinkColors.primary,
                  ),
                ),
              ],
            ),
          ),
          ...devices.where((d) => d.isPossibleNearLinkDevice).map((device) => 
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: _buildDeviceCard(context, provider, device),
            ),
          ),
          const Divider(height: 24),
        ],
        // 其他设备
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _showOnlyPhones 
                ? devices.where((d) => !d.isPossibleNearLinkDevice).length
                : devices.length,
            itemBuilder: (context, index) {
              final filteredDevices = _showOnlyPhones 
                  ? devices.where((d) => !d.isPossibleNearLinkDevice).toList()
                  : devices;
              if (index >= filteredDevices.length) return const SizedBox.shrink();
              final device = filteredDevices[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildDeviceCard(context, provider, device),
              );
            },
          ),
        ),
        _buildFilterBar(provider),
      ],
    );
  }

  Widget _buildDeviceCard(BuildContext context, NearLinkProvider provider, NearbyDevice device) {
    return DeviceCard(
      name: device.name,
      signalLevel: device.signalLevel,
      rssi: device.rssi,
      isConnected: device.isConnected,
      deviceType: device.deviceType,
      isNearLinkDevice: device.isPossibleNearLinkDevice,
      onTap: () => _connectToDevice(context, device),
      onLongPress: () => _showDeviceInfo(context, device),
    );
  }

  Widget _buildFilterBar(NearLinkProvider provider) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(color: Colors.grey.withAlpha((0.2 * 255).toInt())),
        ),
      ),
      child: Row(
        children: [
          // 过滤开关
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: _showOnlyPhones,
                onChanged: (value) {
                  setState(() {
                    _showOnlyPhones = value;
                  });
                },
                activeTrackColor: NearLinkColors.primary.withAlpha((0.5 * 255).toInt()),
                thumbColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return NearLinkColors.primary;
                  }
                  return Colors.grey;
                }),
              ),
              const Text('只显示手机/平板', style: TextStyle(fontSize: 13)),
            ],
          ),
          const Spacer(),
          // 设备数量
          Text(
            '共 ${provider.discoveredDevices.length} 个设备',
            style: const TextStyle(
              fontSize: 12,
              color: NearLinkColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  void _showDeviceInfo(BuildContext context, NearbyDevice device) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: NearLinkColors.primary.withAlpha((0.1 * 255).toInt()),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.info_outline, color: NearLinkColors.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name.isEmpty ? '未知设备' : device.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'ID: ${device.id}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: NearLinkColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildSimpleInfoRow('信号强度', '${device.rssi} dBm (${device.signalLevel} 格)'),
            _buildSimpleInfoRow('设备类型', device.deviceType.name),
            _buildSimpleInfoRow('NearLink', device.isPossibleNearLinkDevice ? '可能是' : '未知'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _connectToDevice(context, device);
                },
                icon: const Icon(Icons.bluetooth),
                label: const Text('尝试连接'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NearLinkColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: NearLinkColors.textSecondary)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, NearLinkProvider provider) {
    // Android 作为 Central 连接到外设，或 iOS 作为 Peripheral 被连接，都显示发送文件按钮
    if (provider.isConnected || provider.isPeripheralConnected) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _selectAndSendFile(context),
                icon: const Icon(Icons.file_open),
                label: const Text('选择文件发送'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NearLinkColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: () {
                if (provider.isPeripheralConnected) {
                  // iOS 作为 Peripheral 被连接，需要特殊处理断开
                  _showDisconnectPeripheralDialog(context, provider);
                } else {
                  provider.disconnect();
                }
              },
              icon: const Icon(Icons.link_off),
              tooltip: '断开连接',
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 扫描按钮
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: provider.connectionState == NearLinkConnectionState.scanning
                      ? () => provider.stopScan()
                      : () => provider.startScan(),
                  icon: Icon(
                    provider.connectionState == NearLinkConnectionState.scanning
                        ? Icons.stop
                        : Icons.bluetooth_searching,
                  ),
                  label: Text(
                    _getScanButtonLabel(provider.connectionState),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NearLinkColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 广播控制按钮
          _buildAdvertiseButton(provider),
        ],
      ),
    );
  }

  /// 构建广播控制按钮
  Widget _buildAdvertiseButton(NearLinkProvider provider) {
    final advertisingState = provider.advertisingState;
    final duration = provider.advertiseDuration;
    
    // 根据状态确定按钮样式
    Color buttonColor;
    IconData icon;
    String label;
    String? subLabel;
    
    switch (advertisingState) {
      case AdvertisingState.starting:
        buttonColor = Colors.orange;
        icon = Icons.wifi_tethering;
        label = '正在开启广播...';
        break;
      case AdvertisingState.advertising:
        buttonColor = Colors.green;
        icon = Icons.wifi_tethering;
        label = '停止广播';
        if (duration != null) {
          final remaining = NearLinkConstants.advertiseTimeout - duration;
          if (remaining > 0) {
            subLabel = '剩余 ${remaining}s';
          } else {
            subLabel = '即将超时';
          }
        } else {
          subLabel = '广播中...';
        }
        break;
      case AdvertisingState.error:
        buttonColor = NearLinkColors.error;
        icon = Icons.error_outline;
        label = '广播出错，点击重试';
        break;
      case AdvertisingState.stopped:
        buttonColor = Colors.blue.shade600;
        icon = Icons.wifi_tethering_off;
        label = '开启广播';
        subLabel = '让其他设备可以发现你';
        break;
      default:
        buttonColor = Colors.blue.shade600;
        icon = Icons.wifi_tethering_off;
        label = '开启广播';
        subLabel = '让其他设备可以发现你';
    }
    
    return Container(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _toggleAdvertising(provider),
        icon: Icon(icon),
        label: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (subLabel != null)
              Text(
                subLabel,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  /// 切换广播状态
  Future<void> _toggleAdvertising(NearLinkProvider provider) async {
    try {
      await provider.toggleAdvertising();
      
      // 显示提示
      if (mounted) {
        final isAdvertising = provider.isAdvertising;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAdvertising ? '广播已开启' : '广播已关闭'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('广播操作失败: $e'),
            backgroundColor: NearLinkColors.error,
          ),
        );
      }
    }
  }



  String _getScanButtonLabel(NearLinkConnectionState state) {
    switch (state) {
      case NearLinkConnectionState.disconnected:
        return '开始扫描';
      case NearLinkConnectionState.scanning:
        return '停止扫描';
      case NearLinkConnectionState.connecting:
        return '连接中...';
      case NearLinkConnectionState.disconnecting:
        return '断开中...';
      case NearLinkConnectionState.connected:
        return '重新扫描';
    }
  }

  Future<void> _connectToDevice(
      BuildContext context, NearbyDevice device) async {
    final provider = context.read<NearLinkProvider>();

    // 静默连接，不显示任何提示
    await provider.connectToDevice(device);
  }

  Future<void> _selectAndSendFile(BuildContext context) async {
    final provider = context.read<NearLinkProvider>();
    final navigator = Navigator.of(context);

    try {
      PlatformFile? selectedFile;
      bool fileFromPicker = false;

      // iOS 使用 image_picker 从相册选择，Android 使用 file_picker
      if (provider.isIOS) {
        // iOS: 使用 image_picker 从相册选择
        final picker = ImagePicker();
        final pickedFile = await picker.pickImage(
          source: ImageSource.gallery,
        );
        
        if (pickedFile != null) {
          // 使用 readAsBytes 获取文件数据，避免 iOS 沙盒路径问题
          final fileBytes = await pickedFile.readAsBytes();
          final fileName = pickedFile.name;
          provider.selectFileWithBytes(fileName, fileBytes);
        } else {
          // 用户取消相册选择，尝试 file_picker 选择其他文件
          final result = await FilePicker.platform.pickFiles(
            type: FileType.any,
            allowMultiple: false,
            withData: true,
          );
          if (result != null && result.files.isNotEmpty) {
            selectedFile = result.files.first;
            fileFromPicker = true;
            provider.selectFile(selectedFile.path!);
          }
        }
      } else {
        // Android: 使用 file_picker
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: true,
        );
        if (result != null && result.files.isNotEmpty) {
          selectedFile = result.files.first;
          fileFromPicker = true;
          provider.selectFile(selectedFile.path!);
        }
      }

      // 检查 widget 是否仍然挂载且有文件被选中
      if (!mounted || !provider.hasSelectedFile) return;

      // 获取文件名用于判断
      final fileName = fileFromPicker
          ? selectedFile!.name
          : (provider.selectedFileName ?? 'photo.jpg');
      final fileSize = fileFromPicker
          ? selectedFile!.size
          : (provider.selectedFileBytes?.length ?? 0);
      final isImage = _isImageFile(fileName);

      // iOS 大文件提示
      if (provider.isIOS && fileSize > 50 * 1024 * 1024) {
        final advice = provider.getIosTransferAdvice(fileSize);
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.info_outline, color: NearLinkColors.warning),
                SizedBox(width: 8),
                Text('传输建议'),
              ],
            ),
            content: Text(advice),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('继续蓝牙传输'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.ios_share),
                label: const Text('使用 AirDrop'),
              ),
            ],
          ),
        );
        return;  // 等待用户选择
      }

      // 如果是图片文件，询问是否压缩
      if (isImage && fileSize > 100 * 1024) {
        final fakeFile = PlatformFile(name: fileName, size: fileSize);
        final shouldCompress = await _showImageCompressionDialog(context, fakeFile);
        if (!mounted) return;
        provider.setCompressImages(shouldCompress);
      }

      // 跳转到传输页面
      navigator.push(
        MaterialPageRoute(
          builder: (context) => const TransferScreen(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择文件失败: $e'),
            backgroundColor: NearLinkColors.error,
          ),
        );
      }
    }
  }
  
  /// 判断是否为图片文件
  bool _isImageFile(String fileName) {
    final lowerName = fileName.toLowerCase();
    return lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.gif') ||
        lowerName.endsWith('.webp') ||
        lowerName.endsWith('.heic') ||
        lowerName.endsWith('.heif');
  }

  /// 显示图片压缩选项对话框
  Future<bool> _showImageCompressionDialog(BuildContext context, PlatformFile file) async {
    final originalSize = _formatFileSizeSimple(file.size);

    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.image, color: NearLinkColors.primary),
            SizedBox(width: 8),
            Text('发送图片'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              file.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              '文件大小: $originalSize',
              style: const TextStyle(color: NearLinkColors.textSecondary),
            ),
            const SizedBox(height: 16),
            const Text(
              '是否压缩图片以加快传输速度？',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NearLinkColors.primary.withAlpha((0.08 * 255).toInt()),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.compress, size: 16, color: NearLinkColors.primary),
                      SizedBox(width: 8),
                      Text(
                        '压缩后优势',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: NearLinkColors.primary,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    '• 传输速度提升 3-10 倍\n'
                    '• 节省蓝牙带宽\n'
                    '• 图片质量仍能保持良好',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('不压缩'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.compress, size: 18),
            label: const Text('压缩发送'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NearLinkColors.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    ) ?? false;
  }

  String _formatFileSizeSimple(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 显示断开 Peripheral 连接的确认对话框（iOS 作为 Peripheral 被连接时）
  void _showDisconnectPeripheralDialog(BuildContext context, NearLinkProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('断开连接后，对方将无法再接收文件。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // iOS 作为 Peripheral 被连接时，只能通过停止广播来断开（实际上已经停止了）
              // 这里主要是重置 UI 状态，真正的断开由 iOS 原生层处理
              provider.stopAdvertising();  // 确保广播停止
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已断开连接')),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: NearLinkColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('断开'),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '设置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('关于我们'),
              subtitle: Text('NearLink v1.0.0'),
            ),
            const ListTile(
              leading: Icon(Icons.privacy_tip_outlined),
              title: Text('隐私政策'),
              subtitle: Text('数据本地存储，不上传云端'),
            ),
            Consumer<NearLinkProvider>(
              builder: (context, provider, _) => SwitchListTile(
                secondary: const Icon(Icons.dark_mode),
                title: const Text('深色模式'),
                value: provider.isDarkMode,
                onChanged: (_) => provider.toggleDarkMode(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
