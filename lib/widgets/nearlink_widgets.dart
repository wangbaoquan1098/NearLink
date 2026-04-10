import 'dart:math';
import 'package:flutter/material.dart';
import '../models/nearlink_models.dart';

/// NearLink 品牌色
class NearLinkColors {
  // 主色
  static const Color primary = Color(0xFF2196F3);
  static const Color primaryLight = Color(0xFF64B5F6);
  static const Color primaryDark = Color(0xFF1976D2);

  // 辅助色
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFF44336);

  // 中性色
  static const Color background = Color(0xFFF5F5F5);
  static const Color surface = Colors.white;
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);

  // 深色主题
  static const Color backgroundDark = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color textPrimaryDark = Color(0xFFFFFFFF);
  static const Color textSecondaryDark = Color(0xFFB0B0B0);

  // 信号强度颜色
  static const Color signalExcellent = Color(0xFF4CAF50);
  static const Color signalGood = Color(0xFF8BC34A);
  static const Color signalFair = Color(0xFFFF9800);
  static const Color signalWeak = Color(0xFFF44336);
}

/// 蓝牙图标动画
class BluetoothSearchingAnimation extends StatefulWidget {
  final double size;
  final Color color;

  const BluetoothSearchingAnimation({
    super.key,
    this.size = 120,
    this.color = NearLinkColors.primary,
  });

  @override
  State<BluetoothSearchingAnimation> createState() =>
      _BluetoothSearchingAnimationState();
}

class _BluetoothSearchingAnimationState
    extends State<BluetoothSearchingAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _rotationAnimation;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat();

    _rotationAnimation = Tween<double>(
      begin: 0,
      end: 2 * pi,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.linear,
    ));

    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 2,
      height: widget.size * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _rotationAnimation,
            builder: (context, child) {
              return Transform.rotate(
                angle: _rotationAnimation.value,
                child: child,
              );
            },
            child: CustomPaint(
              size: Size(widget.size * 1.5, widget.size * 1.5),
              painter: _BluetoothWavePainter(
                color: widget.color.withAlpha((0.3 * 255).toInt()),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: child,
              );
            },
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: widget.color.withAlpha((0.1 * 255).toInt()),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Icon(
            Icons.bluetooth,
            size: widget.size * 0.6,
            color: widget.color,
          ),
        ],
      ),
    );
  }
}

class _BluetoothWavePainter extends CustomPainter {
  final Color color;

  _BluetoothWavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final paint = Paint()
        ..color = color.withAlpha(((0.3 - i * 0.1) * 255).toInt())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      canvas.drawCircle(
        center,
        radius - i * 20,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 信号强度指示器
class SignalStrengthIndicator extends StatelessWidget {
  final int level;
  final double size;
  final Color activeColor;
  final Color inactiveColor;

  const SignalStrengthIndicator({
    super.key,
    required this.level,
    this.size = 24,
    this.activeColor = NearLinkColors.primary,
    this.inactiveColor = const Color(0xFFBDBDBD),
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final height = (index + 1) * (size / 4);
        final isActive = index < level;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          width: size / 6,
          height: height,
          decoration: BoxDecoration(
            color: isActive ? activeColor : inactiveColor,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

/// 设备卡片
class DeviceCard extends StatelessWidget {
  final String name;
  final int signalLevel;
  final int? rssi;
  final bool isConnected;
  final DeviceType? deviceType;
  final bool isNearLinkDevice;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const DeviceCard({
    super.key,
    required this.name,
    required this.signalLevel,
    this.rssi,
    this.isConnected = false,
    this.deviceType,
    this.isNearLinkDevice = false,
    this.onTap,
    this.onLongPress,
  });

  IconData _getDeviceIcon() {
    switch (deviceType) {
      case DeviceType.phone:
        return Icons.phone_android;
      case DeviceType.tablet:
        return Icons.tablet_android;
      case DeviceType.computer:
        return Icons.laptop_mac;
      case DeviceType.audio:
        return Icons.headphones;
      case DeviceType.watch:
        return Icons.watch;
      default:
        return Icons.devices_other;
    }
  }

  Color _getSignalColor() {
    switch (signalLevel) {
      case 4:
        return NearLinkColors.signalExcellent;
      case 3:
        return NearLinkColors.signalGood;
      case 2:
        return NearLinkColors.signalFair;
      default:
        return NearLinkColors.signalWeak;
    }
  }

  String _getSignalText() {
    switch (signalLevel) {
      case 4:
        return '极强';
      case 3:
        return '良好';
      case 2:
        return '一般';
      case 1:
        return '较弱';
      default:
        return '很弱';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: isNearLinkDevice ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isConnected
            ? const BorderSide(color: NearLinkColors.success, width: 2)
            : isNearLinkDevice
                ? BorderSide(color: NearLinkColors.primary.withAlpha((0.5 * 255).toInt()), width: 1)
                : BorderSide.none,
      ),
      color: isNearLinkDevice ? NearLinkColors.primary.withAlpha((0.05 * 255).toInt()) : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 设备图标
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: isNearLinkDevice 
                      ? NearLinkColors.primary.withAlpha((0.15 * 255).toInt())
                      : NearLinkColors.primary.withAlpha((0.08 * 255).toInt()),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _getDeviceIcon(),
                  color: NearLinkColors.primary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 12),
              // 设备信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name.isEmpty ? '未知设备' : name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isNearLinkDevice)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: NearLinkColors.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'NearLink',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // 设备类型
                        if (deviceType != null && deviceType != DeviceType.unknown)
                          Text(
                            _getDeviceTypeText(),
                            style: const TextStyle(
                              fontSize: 11,
                              color: NearLinkColors.textSecondary,
                            ),
                          ),
                        if (deviceType != null && deviceType != DeviceType.unknown && rssi != null)
                          const Text(' • ', style: TextStyle(color: NearLinkColors.textSecondary)),
                        // RSSI 数值
                        if (rssi != null)
                          Text(
                            'RSSI: $rssi dBm',
                            style: TextStyle(
                              fontSize: 11,
                              color: _getSignalColor(),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        if (rssi == null && deviceType == DeviceType.unknown)
                          Text(
                            '信号: ${_getSignalText()}',
                            style: TextStyle(
                              fontSize: 11,
                              color: _getSignalColor(),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 信号强度
              SignalStrengthIndicator(
                level: signalLevel,
                activeColor: _getSignalColor(),
              ),
              const SizedBox(width: 8),
              Icon(
                isConnected ? Icons.check_circle : Icons.chevron_right,
                color: isConnected ? NearLinkColors.success : NearLinkColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getDeviceTypeText() {
    switch (deviceType) {
      case DeviceType.phone:
        return '手机';
      case DeviceType.tablet:
        return '平板';
      case DeviceType.computer:
        return '电脑';
      case DeviceType.audio:
        return '音频设备';
      case DeviceType.watch:
        return '手表';
      default:
        return '设备';
    }
  }
}

/// 传输进度条
class TransferProgressBar extends StatelessWidget {
  final double progress;
  final String? label;
  final Color? color;

  const TransferProgressBar({
    super.key,
    required this.progress,
    this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label!,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color ?? NearLinkColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: NearLinkColors.primary.withAlpha((0.2 * 255).toInt()),
            valueColor: AlwaysStoppedAnimation<Color>(
              color ?? NearLinkColors.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 空状态组件
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 80,
              color: NearLinkColors.textSecondary.withAlpha((0.5 * 255).toInt()),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: NearLinkColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                style: const TextStyle(
                  fontSize: 14,
                  color: NearLinkColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
