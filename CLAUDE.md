# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NearLink** is a Flutter app for cross-platform (Android/iOS) peer-to-peer file transfer over Bluetooth. The app uses BLE discovery + GATT transport, supports both central and peripheral roles, and contains native Android/iOS code to advertise and receive data when the device is acting as a BLE peripheral.

## Common Commands

```bash
# Install dependencies
flutter pub get

# Run app
flutter run
flutter run -d <device_id>

# Analyze
flutter analyze

# Run all tests
flutter test

# Run a single test file
flutter test test/widget_test.dart

# Build release artifacts
flutter build apk
flutter build appbundle
flutter build ios

# iOS native dependency setup
cd ios && pod install
```

At the time this file was updated, `flutter analyze` completed with no issues.

## Architecture Overview

### App structure

The app is organized around a thin Flutter UI layer, a Provider-based app-state layer, and singleton services for BLE and file transfer:

- `lib/main.dart` wires the app with a single `ChangeNotifierProvider` for `NearLinkProvider` and launches `DiscoveryScreen`.
- `lib/providers/nearlink_provider.dart` is the orchestration layer used by the UI. It initializes services, exposes app state to widgets, handles permission flows, and bridges passive connection / incoming transfer events into UI navigation.
- `lib/bluetooth/nearlink_bluetooth_service.dart` owns BLE scanning, connection state, GATT setup, advertising state, packet send/receive, heartbeat monitoring, and platform-channel integration for native peripheral mode.
- `lib/services/file_transfer_service.dart` implements the transfer protocol on top of the Bluetooth service: preparing files, optional image compression, chunking, ACK/batch-ACK flow, receive buffering, persistence, and transfer lifecycle state.
- `lib/models/nearlink_models.dart` defines shared enums, `FileTransfer`, `NearbyDevice`, and the `NearLinkPacket` binary protocol.

### UI flow

There are two main screens:

- `lib/screens/discovery_screen.dart`: scan for devices, start/stop advertising, pick files/photos, and react to passive incoming transfers.
- `lib/screens/transfer_screen.dart`: display live transfer progress, handle disconnect/failure UX, and provide the iOS AirDrop fallback entry point.

Typical active-send flow:

1. `DiscoveryScreen` triggers scan or advertising through `NearLinkProvider`
2. Provider delegates BLE work to `NearLinkBluetoothService`
3. User picks a file/image
4. Provider asks `FileTransferService` to prepare and send it
5. `TransferScreen` observes provider state until completion/failure

Passive receive flow is event-driven: `NearLinkProvider` listens to `FileTransferService` streams and pushes the UI into `TransferScreen` when an incoming transfer is detected.

### State and service patterns

The main service classes are implemented as singletons via factory constructors:

- `NearLinkProvider`
- `NearLinkBluetoothService`
- `FileTransferService`
- `PermissionService`

This means changes in one layer are usually globally visible; avoid assuming fresh instances per screen or per request.

### BLE transport and protocol

`NearLinkPacket` in `lib/models/nearlink_models.dart` is the core on-wire protocol. Packets use a fixed 64-byte header plus payload, with fields for packet type, file ID, chunk index, chunk count, payload size, checksum, and timestamp.

Important protocol details:

- File IDs are UUIDs with hyphens stripped before encoding.
- Packet types include handshake / handshakeAck, fileInfo / fileInfoAck, chunk, chunkAck, batchAck, transferComplete / transferCompleteAck, cancel, error, ping, and pong.
- `NearLinkBluetoothService` maintains a byte buffer to reassemble fragmented BLE writes before decoding full packets.
- `FileTransferService` layers transfer semantics on top of packets: file metadata exchange, chunk streaming, ACK throttling, transfer completion handshakes, and stalled-transfer watchdogs.

### Throughput and chunk sizing

Do not assume one fixed BLE payload size everywhere.

- `NearLinkConstants.maxChunkSize` is **440 bytes**, not 512.
- `FileTransferService` dynamically chooses chunk sizes based on whether the local device is acting as peripheral/central and whether the peer is iOS.
- There is a higher-throughput payload mode (`maxChunkSize * 2`) used in some paths, relying on protocol-level reassembly instead of a strict one-packet-per-ATT-write assumption.

If you change transfer logic, read both:

- `lib/bluetooth/nearlink_bluetooth_service.dart`
- `lib/services/file_transfer_service.dart`

The correctness of one often depends on assumptions in the other.

### Peripheral mode and native platform code

Flutter handles central-mode BLE through `flutter_blue_plus`, but peripheral-mode advertising / receiving depends on native code:

**Android** (`android/app/src/main/kotlin/com/nearlink/nearlink/`)
- `MainActivity.kt` exposes the `com.nearlink/ble_advertise` method channel and `com.nearlink/ble_advertise_events` event channel.
- `BleGattServer.kt` runs the Android GATT server, tracks connected centrals, manages notification subscriptions, fragments outbound notifications to MTU-safe sizes, and reports incoming writes back to Flutter.
- Android advertising identifies NearLink devices via manufacturer data with magic bytes for `NEAR`.

**iOS** (`ios/Runner/`)
- `BleAdvertiser.swift` owns `CBPeripheralManager`, creates the NearLink service/characteristics, handles peripheral advertising, reassembles inbound writes, and emits connection/data events back to Flutter.
- `AppDelegate.swift` installs the method/event channel bridge after Flutter engine startup.
- iOS advertising uses local name + service UUID discovery rather than Android-style manufacturer data.

### Discovery model

Scanning logic in `NearLinkBluetoothService` supports both platform advertisement styles:

- Android advertisers are recognized from manufacturer data.
- iOS advertisers are recognized from service UUID/local-name patterns.
- Discovered devices are deduplicated first by device ID, then by `(platform + name)` to handle address churn.
- The scanner may stop early once the same NearLink device is seen again, treating the result as stabilized.

### Permissions and UX constraints

Permission requests are intentionally **on-demand**, not part of app startup.

- `NearLinkProvider.checkAndRequestPermissions()` first checks adapter power state.
- It then uses `PermissionService` to check/request permissions only when the user initiates scan/advertising.
- The app shows an explanation dialog before requesting system permissions.
- When toggling advertising, permission checks are only needed when starting, not stopping.

Platform specifics:

- Android still requires location permission for BLE scanning.
- iOS uses adapter authorization state rather than explicit runtime Bluetooth permission APIs.
- iOS transfer assumes the app stays in the foreground.
- `TransferScreen` exposes an AirDrop fallback path for iOS.

### Utilities worth knowing

- `lib/utils/extensions.dart`: includes the `Color.o(double)` opacity helper used throughout the UI.
- `lib/utils/file_utils.dart`: centralizes MIME detection, file icons, and size formatting.
- `lib/platforms/android/nfc_dispatcher.dart`: Android-only NFC trigger integration, initialized by `NearLinkProvider`.
- `lib/platforms/ios/ios_platform_adapter.dart`: lightweight iOS platform checks / helpers used by provider and UI logic.

## Testing Notes

Current automated coverage is minimal. The repository currently contains `test/widget_test.dart` and does **not** contain an `integration_test/` directory.

Bluetooth behavior is heavily device- and platform-dependent, so changes to connection, advertising, packet framing, ACK timing, or native peripheral code should be validated on real Android/iOS hardware whenever possible.
