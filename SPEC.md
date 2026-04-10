# NearLink - 跨平台蓝牙文件互传应用技术规格文档

**版本**: 1.0.0  
**更新日期**: 2026-04-01  
**开发者**: NearLink Team

---

## 1. 项目概述

### 1.1 项目背景
NearLink 是一款专注于**无网络环境**下的跨平台（Android/iOS）文件互传应用，通过蓝牙技术实现设备间的快速、稳定文件传输。

### 1.2 核心特性
- **无网络传输**: 无需 WiFi/蜂窝网络，蓝牙 P2P 直连
- **NFC 触发**: Android 端 NFC 触碰快速建立连接
- **文件压缩**: WebP 压缩优化传输效率
- **断点续传**: 分块传输支持中断恢复
- **隐私优先**: 数据本地存储，不上传云端

### 1.3 技术栈
| 组件 | 技术选型 | 备注 |
|------|---------|------|
| 框架 | Flutter 3.x | 跨平台支持 |
| 蓝牙通信 | flutter_blue_plus | BLE/Classic 蓝牙 |
| NFC | nfc_manager | Android NFC 触发 |
| 文件压缩 | flutter_image_compress | WebP 压缩 |
| 状态管理 | Provider / Riverpod | 应用状态 |
| 本地存储 | shared_preferences | 配置持久化 |

---

## 2. 架构设计

### 2.1 应用架构
```
┌─────────────────────────────────────────────────────────┐
│                      UI Layer                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │  设备发现页 │  │  传输页面  │  │  设置页面  │  │  历史页面  │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
├─────────────────────────────────────────────────────────┤
│                   Business Logic Layer                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │NearLink  │  │ File     │  │ NFC      │  │ Share    │ │
│  │Service   │  │Service   │  │Dispatcher│  │Service   │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
├─────────────────────────────────────────────────────────┤
│                     Platform Layer                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Bluetooth Adapter                    │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────────────┐   │  │
│  │  │ BLE GATT│  │Classic  │  │Connection Mgr   │   │  │
│  │  │ Service │  │Socket   │  │                 │   │  │
│  │  └─────────┘  └─────────┘  └─────────────────┘   │  │
│  └──────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────┤
│                     Platform Layer                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Android     │  │     iOS      │  │    Common    │  │
│  │  Platform     │  │   Platform   │  │   Platform   │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 2.2 协议设计

#### 2.2.1 数据包格式
```dart
class NearLinkPacket {
  final PacketType type;           // 数据包类型
  final String fileId;              // 文件唯一标识 (UUID)
  final int chunkIndex;             // 当前块索引
  final int totalChunks;            // 总块数
  final int payloadSize;            // 负载大小
  final String checksum;            // CRC32/MD5 校验
  final Uint8List payload;          // 数据负载
  final int timestamp;              // 时间戳
}
```

#### 2.2.2 数据包类型枚举
```dart
enum PacketType {
  handshake,       // 握手请求
  handshakeAck,    // 握手响应
  fileInfo,        // 文件信息
  fileInfoAck,     // 文件信息确认
  chunk,           // 数据块
  chunkAck,        // 块确认
  transferComplete, // 传输完成
  error,           // 错误消息
  cancel,          // 取消传输
}
```

#### 2.2.3 蓝牙服务 UUID
```dart
// 自定义 GATT 服务 UUID
const String nearLinkServiceUuid = "0000FFFF-0000-1000-8000-00805F9B34FB";
const String nearLinkCharTxUuid = "0000FF01-0000-1000-8000-00805F9B34FB";
const String nearLinkCharRxUuid = "0000FF02-0000-1000-8000-00805F9B34FB";
```

### 2.3 连接建立流程
```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    设备 A     │     │     设备 B     │     │     说明      │
└──────┬───────┘     └──────┬───────┘     └──────────────┘
       │                    │
       │ ── NFC 触碰/扫描 ──►│           Android: NFC 触发
       │                    │           iOS: 蓝牙扫描发现
       │◄── 蓝牙连接 ────────►│           建立 BLE/Classic 连接
       │                    │
       │ ── Handshake ──────►│           交换设备信息
       │◄── HandshakeAck ────│           确认连接
       │                    │
       │ ── FileInfo ───────►│           发送文件元数据
       │◄── FileInfoAck ────│           确认开始传输
       │                    │
       │ ── Chunk 0..N ─────►│           分块传输
       │◄── ChunkAck ────────│           每块确认
       │                    │
       │ ── Complete ───────►│           传输完成
       │◄── CompleteAck ────│           最终确认
       │                    │
```

---

## 3. 平台适配策略

### 3.1 Android 端
| 功能 | 实现方式 | 备注 |
|------|---------|------|
| 蓝牙扫描 | flutter_blue_plus | ACCESS_FINE_LOCATION 必需 |
| 经典蓝牙 | BluetoothClassic | 文件大时使用 |
| BLE GATT | flutter_blue_plus | 小文件传输 |
| NFC 触发 | nfc_manager | 读取 NDEF 启动扫描 |
| 后台保活 | Foreground Service | 传输时保持活跃 |
| 配对弹窗 | 系统原生 | 无需自定义 |

### 3.2 iOS 端
| 功能 | 实现方式 | 备注 |
|------|---------|------|
| 蓝牙扫描 | flutter_blue_plus | 前台必需 |
| CoreBluetooth | 底层支持 | 后台受限 |
| AirDrop 备选 | share_plus | 大文件兜底方案 |
| 权限弹窗 | 系统原生 | 首次请求 |
| 后台保活 | **不支持** | App 需前台运行 |

### 3.3 iOS 限制解决方案
```
┌─────────────────────────────────────────────────────────┐
│                   iOS 文件传输策略                        │
├─────────────────────────────────────────────────────────┤
│  文件大小 < 5MB:                                         │
│  → 使用 BLE GATT 传输                                    │
│                                                         │
│  文件大小 5MB - 50MB:                                    │
│  → 使用 BLE 传输，显示进度条                              │
│  → 保持 App 前台                                          │
│                                                         │
│  文件大小 > 50MB:                                        │
│  → 提示使用 AirDrop 分享                                  │
│  → 显示系统分享面板                                       │
│  → 记录传输历史                                          │
└─────────────────────────────────────────────────────────┘
```

---

## 4. 性能优化策略

### 4.1 蓝牙连接优化
- **扫描策略**: 降低扫描频率（500ms 间隔）
- **连接缓存**: 记住已配对设备，减少重连时间
- **预热连接**: 握手后保持连接 30 秒待命

### 4.2 文件传输优化
- **块大小**: BLE 建议 512 字节，Classic Bluetooth 建议 16KB
- **并发控制**: 同时最多传输 2 个文件
- **压缩策略**: 照片自动 WebP 压缩（质量 80%）
- **压缩比预估**: 原始 3MB → 压缩 300KB（节省 90% 时间）

### 4.3 电池优化
- **扫描超时**: 30 秒无结果自动停止
- **低功耗模式**: 连接稳定后切换至低功耗角色
- **熄屏处理**: 传输时禁用熄屏（仅 Android）

---

## 5. UI/UX 设计规范

### 5.1 视觉风格
- **设计语言**: Material Design 3
- **主题**: 简洁、科技感
- **主色调**: #2196F3 (NearLink Blue)
- **次要色**: #4CAF50 (Success Green)
- **强调色**: #FF5722 (Alert Orange)
- **深色模式**: 支持

### 5.2 页面设计

#### 5.2.1 设备发现页
```
┌─────────────────────────────────────┐
│  ◉ NearLink                    ⚙️  │
├─────────────────────────────────────┤
│                                     │
│           🔵 (蓝牙图标动画)          │
│                                     │
│       正在搜索附近设备...            │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 📱 iPhone - Pro             │   │
│  │    信号强度: ▂▃▅▇            │   │
│  │    [点击连接]               │   │
│  └─────────────────────────────┘   │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 📱 Pixel 8                  │   │
│  │    信号强度: ▂▃▄             │   │
│  │    [点击连接]               │   │
│  └─────────────────────────────┘   │
│                                     │
│  [🔄 重新扫描]    [📋 手动输入]    │
└─────────────────────────────────────┘
```

#### 5.2.2 传输页面
```
┌─────────────────────────────────────┐
│  ← 返回                    📤 传输中 │
├─────────────────────────────────────┤
│                                     │
│       已连接: iPhone Pro            │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 📄 document.pdf              │   │
│  │ ████████████░░░░░░░  67%     │   │
│  │ 2.3 MB / 3.4 MB              │   │
│  └─────────────────────────────┘   │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ 🖼️ photo.jpg                │   │
│  │ ⏳ 等待中...                  │   │
│  └─────────────────────────────┘   │
│                                     │
│  预计剩余时间: 45 秒                 │
│                                     │
│  [❌ 取消传输]                       │
└─────────────────────────────────────┘
```

### 5.3 错误处理提示
| 场景 | 提示文案 | 处理建议 |
|------|---------|---------|
| 蓝牙未开启 | "请开启蓝牙以使用文件传输" | 显示系统设置入口 |
| 位置权限缺失 | "需要位置权限以扫描蓝牙设备" | 引导授权 |
| 连接超时 | "连接超时，请靠近设备重试" | 显示重试按钮 |
| 传输中断 | "传输已中断，是否继续？" | 提供断点续传 |
| 配对失败 | "配对失败，请确认对方已接受" | 引导重新配对 |
| iOS 大文件 | "文件较大，建议使用 AirDrop 分享" | 打开分享面板 |

---

## 6. 依赖配置

### 6.1 pubspec.yaml
```yaml
dependencies:
  flutter:
    sdk: flutter

  # 蓝牙通信
  flutter_blue_plus: ^1.32.0

  # NFC (Android)
  nfc_manager: ^3.5.0

  # 文件选择与处理
  file_picker: ^8.0.0
  path_provider: ^2.1.2

  # 图片压缩
  flutter_image_compress: ^2.1.0

  # 分享 (AirDrop)
  share_plus: ^9.0.0

  # 状态管理
  provider: ^6.1.1

  # 本地存储
  shared_preferences: ^2.2.2

  # UUID 生成
  uuid: ^4.3.3

  # CRC 校验
  crc16: ^1.0.0

  # 权限管理
  permission_handler: ^11.3.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.1
```

### 6.2 Android 配置 (AndroidManifest.xml)
```xml
<!-- 蓝牙权限 -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>

<!-- 位置权限 (蓝牙扫描必需) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>

<!-- NFC 权限 -->
<uses-permission android:name="android.permission.NFC"/>

<!-- 后台服务 -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>

<!-- 特性声明 -->
<uses-feature android:name="android.hardware.bluetooth" android:required="true"/>
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>
<uses-feature android:name="android.hardware.nfc" android:required="false"/>
```

### 6.3 iOS 配置 (Info.plist)
```xml
<!-- 蓝牙权限 -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>NearLink 需要蓝牙权限来发现并连接附近设备进行文件传输</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>NearLink 需要蓝牙权限来发现并连接附近设备进行文件传输</string>

<!-- NFC 权限 -->
<key>NFCReaderUsageDescription</key>
<string>NearLink 使用 NFC 快速触发蓝牙连接</string>

<!-- 照片访问 -->
<key>NSPhotoLibraryUsageDescription</key>
<string>NearLink 需要访问您的照片以进行文件传输</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>NearLink 需要保存接收到的文件</string>

<!-- 文件访问 -->
<key>UISupportsDocumentBrowser</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

---

## 7. 安全与隐私

### 7.1 数据安全
- **本地存储**: 所有文件存储在应用私有目录
- **传输加密**: BLE 模式下使用固定密钥加密
- **权限最小化**: 仅申请必要权限

### 7.2 隐私声明
```
NearLink 隐私政策

1. 数据收集
   - NearLink 不会收集、存储或上传任何用户数据至云端
   - 所有文件传输均在设备间直接进行（P2P）

2. 权限使用
   - 蓝牙: 仅用于发现并连接附近设备
   - 位置: 蓝牙扫描需要（Android 系统要求）
   - 照片: 仅用于选择要传输的文件

3. 数据存储
   - 接收的文件存储在应用私有目录
   - 传输完成后可手动删除

4. 隐私合规
   - 符合 GDPR 基本要求
   - 不包含任何追踪器或分析 SDK
```

---

## 8. App Store 审核清单

### 8.1 功能完整性
- [ ] 蓝牙文件传输功能可用
- [ ] NFC 触发功能可用（Android）
- [ ] AirDrop 兜底方案可用（iOS）
- [ ] 文件接收和保存功能可用

### 8.2 权限说明
- [ ] 所有权限描述清晰、无歧义
- [ ] 权限申请有合理用途说明
- [ ] 用户可理解为何需要这些权限

### 8.3 隐私合规
- [ ] 隐私政策页面完整
- [ ] 不包含任何追踪器
- [ ] 数据不上传云端说明清晰

### 8.4 技术合规
- [ ] iOS: App 在前台运行
- [ ] Android: 后台服务有前台通知
- [ ] 无崩溃或严重 Bug

### 8.5 文案审核
- [ ] 应用名称: NearLink
- [ ] 描述中强调"本地 P2P 传输"
- [ ] 不声称"无需任何权限"
- [ ] 不包含误导性表述

---

## 9. 测试用例

### 9.1 Android 测试
| 测试项 | 步骤 | 预期结果 |
|-------|------|---------|
| 蓝牙开启 | 关闭蓝牙 → 打开 App → 提示开启 | 显示开启蓝牙提示 |
| 权限申请 | 首次打开 → 点击发送 | 显示权限申请弹窗 |
| 设备扫描 | 两台设备打开 App | 显示对方设备 |
| NFC 触发 | NFC 触碰 | 自动开始蓝牙扫描 |
| 文件传输 | 选择文件 → 发送 → 接收 | 文件正确接收 |
| 后台传输 | 按 Home → 切后台 | 继续传输，显示通知 |

### 9.2 iOS 测试
| 测试项 | 步骤 | 预期结果 |
|-------|------|---------|
| 蓝牙开启 | 关闭蓝牙 → 打开 App → 提示开启 | 显示开启蓝牙提示 |
| 权限申请 | 首次打开 → 点击发送 | 显示权限申请弹窗 |
| 设备扫描 | 两台设备打开 App | 显示对方设备 |
| AirDrop 兜底 | 发送 > 50MB 文件 | 提示使用 AirDrop |
| 前台保活 | 按 Home | 传输暂停，显示提示 |
| 文件接收 | 接收文件 → 保存 | 文件正确保存 |

---

## 10. 后续规划

### v1.1.0 (预计)
- Wi-Fi Direct 备选传输
- 多文件批量传输
- 传输历史记录

### v1.2.0 (预计)
- Apple Watch / Android Wear 支持
- 联系人免配对快速连接
- 传输加密升级

### v2.0.0 (预计)
- 跨平台云端备份（可选功能）
- 家庭共享功能
- 深色模式优化

---

**文档结束**
