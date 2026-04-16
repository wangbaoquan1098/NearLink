# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NearLink** is a cross-platform (Android/iOS) Bluetooth file transfer app built with Flutter. It enables P2P file sharing without requiring internet connectivity. The app uses BLE GATT for small files (<5MB) and falls back to AirDrop for large files on iOS.

## Common Commands

```bash
# Install dependencies
flutter pub get

# Run the app (debug mode)
flutter run

# Run on specific device
flutter run -d <device_id>

# Build for production
flutter build apk              # Android APK
flutter build appbundle      # Android App Bundle
flutter build ios            # iOS (requires macOS & Xcode)

# Analyze and lint
flutter analyze

# Run tests
flutter test

# iOS specific setup
cd ios && pod install
```

## Architecture Overview

### Core Services (Singleton Pattern)

The app uses a service-oriented architecture with singletons for state management:

1. **NearLinkBluetoothService** (`lib/bluetooth/nearlink_bluetooth_service.dart`)
   - Central BLE manager for scanning, connecting, and GATT communication
   - Handles both Central and Peripheral modes
   - Supports both Android and iOS native advertising via MethodChannel
   - Key constants: `NearLinkConstants.serviceUuid`, `charTxUuid`, `charRxUuid`
   - Max chunk size: 512 bytes (BLE MTU limit)

2. **FileTransferService** (`lib/services/file_transfer_service.dart`)
   - Manages file preparation, chunking, and transfer state
   - Handles image compression via `flutter_image_compress`
   - Tracks received chunks for resume support

3. **NearLinkProvider** (`lib/providers/nearlink_provider.dart`)
   - Main application state management using Provider pattern
   - Bridges UI with Bluetooth and FileTransfer services
   - Manages passive connection events and file reception

### Protocol Layer

**NearLinkPacket** (`lib/models/nearlink_models.dart`) defines the binary protocol:

```dart
// Packet structure (64-byte header + payload)
- Type (1 byte)
- FileId (32 bytes, hyphen-stripped UUID)
- ChunkIndex (2 bytes, big-endian)
- TotalChunks (2 bytes, big-endian)
- PayloadSize (2 bytes, big-endian)
- Checksum (8 bytes, CRC32 hex)
- Timestamp (4 bytes, big-endian)
- Reserved (13 bytes)
```

Packet types: `handshake`, `fileInfo`, `chunk`, `chunkAck`, `transferComplete`, `cancel`, `error`, `ping/pong`

### Platform-Specific Code

**Android** (`android/app/src/main/kotlin/com/nearlink/nearlink/`):
- `MainActivity.kt`: Flutter entry point
- `BleGattServer.kt`: BLE Peripheral (GATT server) implementation
- MethodChannel: `com.nearlink/ble_advertise`

**iOS** (`ios/Runner/`):
- `BleAdvertiser.swift`: CoreBluetooth peripheral advertising
- `AppDelegate.swift`: App lifecycle handling
- EventChannel: `com.nearlink/ble_advertise_events`

### Key Design Decisions

1. **Dual Advertising Strategy**:
   - Android: Uses Manufacturer Data with magic bytes `0x4E, 0x45, 0x41, 0x52` ("NEAR")
   - iOS: Uses Service UUID advertising (0xFFFF) since Manufacturer Data is restricted

2. **Connection Modes**:
   - Central mode: App scans and connects to other devices
   - Peripheral mode: App advertises and accepts connections (native implementation required)

3. **Platform Differences**:
   - Android supports background file transfer via foreground service
   - iOS requires app to remain in foreground during transfer
   - Files >50MB on iOS trigger AirDrop fallback via `share_plus`

4. **Data Flow**:
   - DiscoveryScreen → TransferScreen for active sending
   - Provider streams (`onIncomingConnection`, `onTransferReceived`) handle passive reception

## Dependencies to Know

- `flutter_blue_plus`: BLE communication (the core dependency)
- `nfc_manager`: Android NFC trigger (optional feature)
- `flutter_image_compress`: WebP compression for photos
- `share_plus`: AirDrop fallback on iOS
- `provider`: State management
- `permission_handler`: Runtime permissions (Bluetooth, Location, Photos)

## Testing

The project currently has minimal test coverage. Tests should be added to the `test/` directory. Integration tests require physical devices due to Bluetooth hardware dependency.

## Utility Files

- **ColorOpacity Extension** (`lib/utils/extensions.dart`)
  - Provides `.o(double)` method for colors: `NearLinkColors.primary.o(0.1)`
  - Replaces verbose `.withAlpha((0.x * 255).toInt())` pattern
  - Also includes BuildContext, String, and Duration extensions

- **File Utilities** (`lib/utils/file_utils.dart`)
  - Centralized MIME type detection and file icon mapping
  - File size formatting (KB, MB, GB)
  - Used by TransferScreen for consistent file display

## Permission Handling Pattern

Permissions are requested on-demand (not at startup) to improve UX:

1. **Delayed Request**: `checkAndRequestPermissions()` is called when user performs an action (scan/advertise), not during app init
2. **Explanation First**: Shows permission explanation dialog before system dialog
3. **State-aware**: When toggling advertising, only check permissions when starting (not stopping)

See: `lib/providers/nearlink_provider.dart` lines 194-215 and `lib/screens/discovery_screen.dart` lines 736-746

## Common Issues

- **iOS**: Background execution is restricted; app must stay in foreground during transfer
- **Android**: Location permission required for Bluetooth scanning (system requirement)
- **MTU negotiation**: iOS max MTU is 185, Android supports up to 517
- **Packet parsing**: The `_onDataReceived` method handles BLE packet fragmentation ("sticky packets")
