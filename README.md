# NearLink - 跨平台蓝牙文件互传应用

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-blue" alt="Flutter">
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20iOS-green" alt="Platform">
  <img src="https://img.shields.io/badge/License-MIT-orange" alt="License">
</p>

## 📱 应用介绍

**NearLink** 是一款专注于**无网络环境**下的跨平台（Android/iOS）文件互传应用，通过蓝牙技术实现设备间的快速、稳定文件传输。

### 核心特性

- **无网络传输**: 无需 WiFi/蜂窝网络，蓝牙 P2P 直连
- **NFC 触发**: Android 端 NFC 触碰快速建立连接
- **文件压缩**: WebP 压缩优化传输效率
- **断点续传**: 分块传输支持中断恢复
- **隐私优先**: 数据本地存储，不上传云端

## 🚀 快速开始

### 环境要求

- Flutter SDK 3.x
- Dart 3.x
- Android Studio / Xcode
- Android SDK (API 21+)
- Xcode 14+ (for iOS)

### 安装依赖

```bash
# 克隆项目
git clone https://github.com/your-org/nearlink.git
cd nearlink

# 安装依赖
flutter pub get

# 运行应用
flutter run
```

### iOS 配置

```bash
# 进入 iOS 目录
cd ios

# 安装 CocoaPods 依赖
pod install
```

## 📁 项目结构

```
lib/
├── main.dart                    # 应用入口
├── models/
│   └── nearlink_models.dart     # 数据模型
├── bluetooth/
│   └── nearlink_bluetooth_service.dart  # 蓝牙服务
├── services/
│   ├── file_transfer_service.dart      # 文件传输服务
│   └── permission_service.dart         # 权限服务
├── platforms/
│   ├── android/
│   │   └── nfc_dispatcher.dart          # NFC 调度器
│   └── ios/
│       └── ios_platform_adapter.dart   # iOS 平台适配
├── providers/
│   └── nearlink_provider.dart          # 状态管理
├── screens/
│   ├── discovery_screen.dart           # 设备发现页
│   └── transfer_screen.dart            # 传输页面
└── widgets/
    └── nearlink_widgets.dart           # UI 组件
```

## 🔧 技术架构

### 蓝牙协议设计

```dart
// 数据包结构
class NearLinkPacket {
  PacketType type;     // 数据包类型
  String fileId;       // 文件唯一标识
  int chunkIndex;       // 当前块索引
  int totalChunks;      // 总块数
  String checksum;      // CRC32 校验
  Uint8List payload;   // 数据负载
}
```

### 传输流程

```
设备 A ←→ 设备 B
  ↓          ↓
1. 扫描发现
2. 建立连接
3. 握手交换
4. 文件分块
5. 数据传输
6. 校验确认
7. 传输完成
```

## 📋 平台差异处理

| 功能 | Android | iOS | 说明 |
|------|---------|-----|------|
| 蓝牙扫描 | ✅ | ✅ | |
| BLE GATT 传输 | ✅ | ✅ | |
| Classic Bluetooth | ✅ | ❌ | iOS 不支持 |
| NFC 触发 | ✅ | ❌ | iOS 限制较多 |
| 后台传输 | ✅ | ❌ | iOS 前台必需 |
| AirDrop 兜底 | ❌ | ✅ | 大文件建议使用 |

## 🔒 隐私说明

NearLink 郑重承诺：

1. **数据不上云**: 所有文件传输均在设备间直接进行（P2P），不经过任何服务器
2. **权限最小化**: 仅申请必要的蓝牙和存储权限
3. **本地存储**: 接收的文件存储在应用私有目录
4. **无追踪**: 不包含任何分析 SDK 或追踪器

详细隐私政策请查看 [PRIVACY_POLICY.md](PRIVACY_POLICY.md)

## 🧪 测试

```bash
# 运行单元测试
flutter test

# 运行集成测试
flutter test integration_test/

# 设备测试
flutter test -d <device_id>
```

## 📝 开发指南

### 添加新功能

1. 创建功能分支 `git checkout -b feature/your-feature`
2. 编写代码和测试
3. 提交 Pull Request
4. 代码审查后合并

### 代码规范

- 遵循 [Flutter Style Guide](https://github.com/flutter/flutter/wiki/Style-guide-for-Flutter-repo)
- 使用 `flutter analyze` 检查代码
- 所有公开 API 需要文档注释

## ⚠️ 注意事项

### Android
- Android 6.0+ 需要动态申请位置权限
- 部分设备可能需要开启"精确位置"权限
- NFC 功能仅部分设备支持

### iOS
- App 需要在**前台运行**才能进行蓝牙传输
- 传输大文件（>50MB）建议使用 **AirDrop**
- 首次使用需要授权蓝牙和位置权限

## 📄 许可证

本项目采用 MIT 许可证，详见 [LICENSE](LICENSE) 文件。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📞 联系方式

- 邮箱: contact@nearlink.app
- 网站: https://nearlink.app

---

<p align="center">
  Made with ❤️ by NearLink Team
</p>
