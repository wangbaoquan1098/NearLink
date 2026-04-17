import Foundation
import CoreBluetooth
import Flutter

/// iOS BLE 广播管理器
class BleAdvertiser: NSObject, CBPeripheralManagerDelegate {
    private var peripheralManager: CBPeripheralManager?
    private var isAdvertising = false
    private var shouldStartAdvertising = false
    private var pendingDeviceName: String = "NearLink"
    
    // NearLink 服务 UUID
    private let serviceUUID = CBUUID(string: "0000FFFF-0000-1000-8000-00805F9B34FB")
    private let charTxUUID = CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB")
    private let charRxUUID = CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB")
    
    // 特征值
    private var txCharacteristic: CBMutableCharacteristic?
    private var rxCharacteristic: CBMutableCharacteristic?
    private var nearlinkService: CBMutableService?
    
    // 连接的中心设备
    private var connectedCentrals: [CBCentral] = []
    
    // 存储已协商的 MTU（用于优化发送大小）
    private var negotiatedMtu: Int = 185  // iOS 默认 BLE MTU
    
    // 发送队列（当准备队列满时暂存数据）
    private var pendingDataQueue: [Data] = []
    
    // Flutter Event Channel（用于向Flutter发送连接事件）
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    private var pendingEvents: [[String: Any]] = []
    private var channelsConfigured = false
    
    // 数据包重组缓冲区
    private var reassemblyBuffer: Data = Data()
    
    // NearLink 包头部大小
    private let nearlinkHeaderSize = 64

    private func shortFileId(from packet: Data) -> String {
        guard packet.count >= 33 else { return "" }
        let fileIdBytes = packet.subdata(in: 1..<33)
        let filtered = fileIdBytes.filter { $0 != 0 }
        let fileId = String(data: Data(filtered), encoding: .utf8) ?? ""
        return String(fileId.prefix(8))
    }

    private func packetTypeName(_ type: UInt8) -> String {
        switch type {
        case 2: return "fileInfo"
        case 3: return "fileInfoAck"
        case 8: return "transferComplete"
        case 9: return "transferCompleteAck"
        case 10: return "cancel"
        case 11: return "ping"
        case 12: return "pong"
        default: return "type\(type)"
        }
    }
    
    static let shared = BleAdvertiser()
    
    private override init() {
        super.init()
        // 初始化外围设备管理器
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    private func emitEvent(_ eventData: [String: Any]) {
        if let sink = eventSink {
            sink(eventData)
        } else {
            pendingEvents.append(eventData)
        }
    }
    
    /// 开始广播（供 Dart 层调用）
    func startAdvertising(deviceName: String) -> Bool {
        pendingDeviceName = deviceName
        
        guard let peripheral = peripheralManager else {
            return false
        }
        
        // 如果蓝牙已开启，立即开始广播
        if peripheral.state == .poweredOn {
            return startAdvertisingInternal(deviceName: deviceName)
        } else {
            // 否则标记为待启动
            shouldStartAdvertising = true
            return true
        }
    }
    
    /// 停止广播
    func stopAdvertising() {
        shouldStartAdvertising = false
        peripheralManager?.stopAdvertising()
        isAdvertising = false
    }

    /// 主动断开所有已连接的中心设备
    func disconnect() {
        shouldStartAdvertising = false
        stopAdvertising()

        let disconnectedCentrals = connectedCentrals
        connectedCentrals.removeAll()
        pendingDataQueue.removeAll()
        reassemblyBuffer = Data()
        negotiatedMtu = 185

        peripheralManager?.removeAllServices()
        txCharacteristic = nil
        rxCharacteristic = nil
        nearlinkService = nil
        isServiceAdded = false

        for central in disconnectedCentrals {
            emitEvent([
                "event": "centralDisconnected",
                "centralId": central.identifier.uuidString
            ])
        }

        // 重建 peripheral manager，确保已连接的 central 真正失效，后续也能重新广播。
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    /// 内部开始广播
    private func startAdvertisingInternal(deviceName: String) -> Bool {
        guard let peripheral = peripheralManager,
              peripheral.state == .poweredOn else {
            return false
        }
        
        if isAdvertising {
            return true
        }
        
        // 确保服务已设置
        if nearlinkService == nil {
            setupGattService()
        }
        
        // 等待服务添加成功后再广播（服务添加是异步的）
        if !isServiceAdded {
            shouldStartAdvertising = true
            pendingDeviceName = deviceName
            return true  // 返回 true，表示请求已接受，等待服务就绪
        }
        
        // 构建广播数据
        // iOS 限制：广播包大小有限，我们使用 Local Name 和 Service UUID
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: deviceName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
        
        peripheral.startAdvertising(advertisementData)
        return true
    }
    
    /// 设置 GATT 服务
    private func setupGattService() {
        guard let peripheral = peripheralManager,
              peripheral.state == .poweredOn else {
            return
        }
        
        // 创建 TX 特征值（Notify + WriteWithoutResponse）
        // 注意：CCCD 描述符是系统保留的，不能手动创建，系统会自动处理 notify 订阅
        txCharacteristic = CBMutableCharacteristic(
            type: charTxUUID,
            properties: [.notify, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        // 创建 RX 特征值（Write + WriteWithoutResponse）- 用于接收中心设备的数据
        rxCharacteristic = CBMutableCharacteristic(
            type: charRxUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        // 创建 NearLink 服务
        nearlinkService = CBMutableService(type: serviceUUID, primary: true)
        nearlinkService?.characteristics = [txCharacteristic!, rxCharacteristic!]
        
        // 添加服务
        peripheral.add(nearlinkService!)
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // 蓝牙已开启，设置 GATT 服务
            // 注意：服务添加是异步的，需要等待 didAdd 回调
            setupGattService()
            
        case .poweredOff:
            isAdvertising = false
            isServiceAdded = false
            
        default:
            break
        }
    }
    
    // 标记服务是否已添加成功
    private var isServiceAdded = false
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            isServiceAdded = false
        } else {
            isServiceAdded = true
            
            // 如果有待启动的广播请求，现在可以开始了
            if shouldStartAdvertising {
                _ = startAdvertisingInternal(deviceName: pendingDeviceName)
                shouldStartAdvertising = false
            }
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if error == nil {
            isAdvertising = true
        } else {
            isAdvertising = false
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // 简单响应
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // 高频打印已禁用以提升性能
        // print("[BleAdvertiser] didReceiveWrite: received \(requests.count) requests")

        // 合并所有请求的数据
        var combinedData = Data()
        for (_, request) in requests.enumerated() {
            if let value = request.value {
                // print("[BleAdvertiser] request[\(index)]: characteristic=\(request.characteristic.uuid), dataSize=\(value.count)")
                combinedData.append(value)
            }
        }

        // print("[BleAdvertiser] combinedData size: \(combinedData.count)")

        if combinedData.isEmpty {
            for request in requests {
                if request.characteristic.properties.contains(.write) {
                    peripheral.respond(to: request, withResult: .success)
                }
            }
            return
        }

        // 将数据加入重组缓冲区
        reassemblyBuffer.append(combinedData)
        if reassemblyBuffer.count >= nearlinkHeaderSize {
            let type = reassemblyBuffer[0]
            if type == 2 || type == 3 || type == 8 || type == 9 || type == 10 {
                NSLog(
                    "[BleAdvertiser][trace] didReceiveWrite append type=%@ file=%@ buffer=%d",
                    packetTypeName(type),
                    shortFileId(from: reassemblyBuffer),
                    reassemblyBuffer.count
                )
            }
        }

        // 处理重组缓冲区的数据
        processReassemblyBuffer()
        
        // 对每个写请求发送响应
        for request in requests {
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
    
    /// 处理重组缓冲区，尝试解析完整的包
    private func processReassemblyBuffer() {
        // 高频打印已禁用以提升性能
        // 循环处理，直到缓冲区数据不足或处理完所有完整包
        while reassemblyBuffer.count >= nearlinkHeaderSize {
            // 验证协议头
            let type = reassemblyBuffer[0]
            
            // 检查 type 是否在有效范围内 (0-19)
            if type > 19 {
                // 可能是上一个包的剩余数据，检查是否有下一个包的开始
                if reassemblyBuffer.count >= nearlinkHeaderSize {
                    var foundValidPacket = false
                    for offset in 1..<min(reassemblyBuffer.count - nearlinkHeaderSize, 10) {
                        let potentialType = reassemblyBuffer[offset]
                        if potentialType <= 19 {
                            reassemblyBuffer = reassemblyBuffer.subdata(in: offset..<reassemblyBuffer.count)
                            foundValidPacket = true
                            break
                        }
                    }
                    if !foundValidPacket {
                        reassemblyBuffer = Data()
                        break
                    }
                } else {
                    break
                }
            } else {
                // 有效包头，继续处理
                break
            }
        }
        
        // 检查是否至少有完整的头部
        guard reassemblyBuffer.count >= nearlinkHeaderSize else {
            return
        }
        
        // 解析 payloadSize
        let payloadSize = Int(reassemblyBuffer[37]) << 8 | Int(reassemblyBuffer[38])
        let totalPacketLength = nearlinkHeaderSize + payloadSize
        
        // 安全检查
        if payloadSize > 65535 || totalPacketLength > 1000000 {
            reassemblyBuffer = Data()
            return
        }
        
        // 检查是否完整
        if reassemblyBuffer.count >= totalPacketLength {
            // 提取完整包
            let packet = reassemblyBuffer.subdata(in: 0..<totalPacketLength)
            reassemblyBuffer = reassemblyBuffer.subdata(in: totalPacketLength..<reassemblyBuffer.count)
            let type = packet[0]
            if type == 2 || type == 3 || type == 8 || type == 9 || type == 10 {
                NSLog(
                    "[BleAdvertiser][trace] packet complete type=%@ file=%@ remaining=%d",
                    packetTypeName(type),
                    shortFileId(from: packet),
                    reassemblyBuffer.count
                )
            }
            
            // 转发给 Flutter
            let eventData: [String: Any] = [
                "event": "dataReceived",
                "characteristicUuid": "0000FF02-0000-1000-8000-00805F9B34FB",
                "data": FlutterStandardTypedData(bytes: packet)
            ]
            emitEvent(eventData)
            
            // 如果缓冲区还有数据，递归处理
            if reassemblyBuffer.count >= nearlinkHeaderSize {
                processReassemblyBuffer()
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        // 新设备连接，清理之前的缓冲区（避免残留数据影响新传输）
        if !reassemblyBuffer.isEmpty {
            reassemblyBuffer = Data()
        }
        if !pendingDataQueue.isEmpty {
            pendingDataQueue.removeAll()
        }

        // 记录连接的中心设备
        if !connectedCentrals.contains(where: { $0.identifier == central.identifier }) {
            connectedCentrals.append(central)
        }

        // 停止广播（有设备连接后不再广播）
        if isAdvertising {
            stopAdvertising()
        }

        // 存储协商的 MTU
        negotiatedMtu = central.maximumUpdateValueLength
        
        // 通知 Flutter 有设备连接
        let eventData: [String: Any] = [
            "event": "centralConnected",
            "centralId": central.identifier.uuidString,
            "mtu": negotiatedMtu
        ]
        emitEvent(eventData)
        
        // 发送队列中的所有待处理数据
        flushPendingDataQueue()
    }
    
    /// 批量添加数据到发送队列（高效批量发送）
    func sendDataBatch(_ packets: [Data]) -> Bool {
        guard let peripheral = peripheralManager, peripheral.state == .poweredOn else {
            return false
        }

        // 检查是否有已连接的中心设备
        if connectedCentrals.isEmpty {
            return false
        }
        for packet in packets {
            enqueueSegmentedData(packet)
        }

        // 立即开始发送
        flushPendingDataQueueFast()

        return true
    }

    /// 快速发送队列中的数据（优化版本，减少延迟）
    private func flushPendingDataQueueFast() {
        guard let txChar = txCharacteristic,
              let peripheral = peripheralManager,
              peripheral.state == .poweredOn else {
            return
        }

        // 检查是否有订阅者
        let subscribers = txChar.subscribedCentrals
        guard let targetCentrals = subscribers, !targetCentrals.isEmpty else {
            // print("[BleAdvertiser] flushPendingDataQueueFast: no subscribers")
            return
        }

        var sentCount = 0
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 8

        // 快速发送循环，最小化延迟
        while !pendingDataQueue.isEmpty && consecutiveFailures < maxConsecutiveFailures {
            let data = pendingDataQueue.removeFirst()

            // 直接发送，不检查数据大小（应用层已分块）
            let didSend = peripheral.updateValue(data, for: txChar, onSubscribedCentrals: targetCentrals)

            if !didSend {
                // 队列已满，放回并等待回调
                pendingDataQueue.insert(data, at: 0)
                consecutiveFailures += 1

                if consecutiveFailures >= maxConsecutiveFailures {
                    // 等待 peripheralManagerIsReady 回调再继续
                    break
                }

                // 极短暂让出时间片，但不 sleep
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0001))
            } else {
                consecutiveFailures = 0
                sentCount += 1

                // 每 40 个包让出一次时间片，减少调度开销
                if sentCount % 40 == 0 {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0001))
                }
            }

            // 单次批量发送上限（避免阻塞太久）
            if sentCount >= 200 {
                // 还有数据未发送，但先让出时间片
                if !pendingDataQueue.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.flushPendingDataQueueFast()
                    }
                }
                break
            }
        }

        // 高频打印已禁用以提升性能
        // print("[BleAdvertiser] flushPendingDataQueueFast: sent=\(sentCount), remaining=\(pendingDataQueue.count)")
    }

    /// 发送队列中的所有待处理数据（兼容旧版本）
    private func flushPendingDataQueue() {
        flushPendingDataQueueFast()
    }

    private func handleCentralDisconnected(_ central: CBCentral, reason: String) {
        let hadCentral = connectedCentrals.contains { $0.identifier == central.identifier }
        if !hadCentral {
            return
        }

        NSLog(
            "[BleAdvertiser][trace] central disconnected reason=%@ central=%@",
            reason,
            central.identifier.uuidString
        )

        connectedCentrals.removeAll { $0.identifier == central.identifier }

        if !reassemblyBuffer.isEmpty {
            reassemblyBuffer = Data()
        }
        if !pendingDataQueue.isEmpty {
            pendingDataQueue.removeAll()
        }

        emitEvent([
            "event": "centralDisconnected",
            "centralId": central.identifier.uuidString
        ])

        if !connectedCentrals.isEmpty {
            return
        }

        if peripheralManager?.state == .poweredOn && !isAdvertising {
            startAdvertising(deviceName: pendingDeviceName)
        }
    }

    /// CoreBluetooth 的 `maximumUpdateValueLength` 已经是单次 updateValue 的安全上限。
    private func maxOutgoingFragmentSize() -> Int {
        let centralLimit = connectedCentrals.map { $0.maximumUpdateValueLength }.min() ?? negotiatedMtu
        let safeLimit = centralLimit > 0 ? centralLimit : negotiatedMtu
        return max(20, safeLimit)
    }

    /// 将 NearLink 包切成 ATT 可承载的多个片段，供 Android 端在 Flutter 层重组。
    private func enqueueSegmentedData(_ data: Data) {
        let fragmentSize = maxOutgoingFragmentSize()

        if data.count <= fragmentSize {
            pendingDataQueue.append(data)
            return
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + fragmentSize, data.count)
            pendingDataQueue.append(data.subdata(in: offset..<end))
            offset = end
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let remainingSubscribers = txCharacteristic?.subscribedCentrals ?? []
        let stillSubscribed = remainingSubscribers.contains { $0.identifier == central.identifier }
        if stillSubscribed {
            return
        }

        // 某些系统版本上，中心设备主动断开后只会先收到取消订阅事件。
        // 当当前 central 已不再订阅且没有其他订阅者时，提前把它视为断连，
        // 避免 Flutter 侧长时间卡在“仍已连接”的状态。
        if remainingSubscribers.isEmpty {
            handleCentralDisconnected(central, reason: "unsubscribe")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didDisconnectCentral central: CBCentral, error: Error?) {
        handleCentralDisconnected(central, reason: "didDisconnect")
    }
    
    /// 发送数据到已连接的中心设备
    /// 数据会自动分块发送以适应 MTU
    func sendDataToCentrals(_ data: Data) -> Bool {
        guard let txChar = txCharacteristic else {
            return false
        }

        // 检查蓝牙是否开启
        guard let peripheral = peripheralManager, peripheral.state == .poweredOn else {
            enqueueSegmentedData(data)
            return false
        }

        // 检查是否有已连接的中心设备
        if connectedCentrals.isEmpty {
            enqueueSegmentedData(data)
            return false
        }

        // 检查是否有订阅者
        let subscribers = txChar.subscribedCentrals
        // print("[BleAdvertiser] sendDataToCentrals: connectedCentrals=\(connectedCentrals.count), subscribers=\(subscribers?.count ?? 0)")

        if subscribers == nil || subscribers!.isEmpty {
            // print("[BleAdvertiser] sendDataToCentrals: no subscribers to TX char, queueing data")
            enqueueSegmentedData(data)
            // 即使没有订阅者，也返回 true 表示数据已入队
            // 数据会在 Android 订阅后通过 didSubscribeTo -> flushPendingDataQueue 发送
            return true
        }

        enqueueSegmentedData(data)
        flushPendingDataQueueFast()

        // print("[BleAdvertiser] sendDataToCentrals: queued \(data.count) bytes as fragments, queue size = \(pendingDataQueue.count)")
        return true
    }
    
    /// 获取已连接的中心设备数量
    func getConnectedCentralsCount() -> Int {
        return connectedCentrals.count
    }

    /// 获取当前待发送分片数量
    func getPendingNotificationCount() -> Int {
        return pendingDataQueue.count
    }

    func clearPendingNotifications() -> Bool {
        pendingDataQueue.removeAll()
        return true
    }

    func clearTransferBuffers() -> Bool {
        NSLog(
            "[BleAdvertiser][trace] clearTransferBuffers queue=%d reassembly=%d",
            pendingDataQueue.count,
            reassemblyBuffer.count
        )
        pendingDataQueue.removeAll()
        reassemblyBuffer = Data()
        return true
    }
    
    // MARK: - 连接状态监听
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // 发送队列中的所有待处理数据
        // print("[BleAdvertiser] peripheralManagerIsReady: ready to send more data, queue size = \(pendingDataQueue.count)")

        // 检查蓝牙状态
        if peripheral.state != .poweredOn {
            // print("[BleAdvertiser] peripheralManagerIsReady: peripheral not powered on, state=\(peripheral.state.rawValue)")
            return
        }

        // 检查是否有订阅者
        guard let txChar = txCharacteristic else {
            // print("[BleAdvertiser] peripheralManagerIsReady: txCharacteristic is nil")
            return
        }

        let subscribers = txChar.subscribedCentrals
        // print("[BleAdvertiser] peripheralManagerIsReady: subscribers count = \(subscribers?.count ?? 0)")

        if subscribers == nil || subscribers!.isEmpty {
            // print("[BleAdvertiser] peripheralManagerIsReady: no subscribers, cannot send data")
            return
        }

        flushPendingDataQueue()
        // print("[BleAdvertiser] peripheralManagerIsReady: after flush, queue size = \(pendingDataQueue.count)")

        // 如果队列还有数据，继续等待下一次回调
        if !pendingDataQueue.isEmpty {
            // print("[BleAdvertiser] peripheralManagerIsReady: queue still has data, waiting for next callback")
        }
    }
    
    // MARK: - Helper
    
    private func stateString(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Flutter Method Channel

extension BleAdvertiser: FlutterStreamHandler {
    func setupMethodChannel(with controller: FlutterViewController) {
        if channelsConfigured {
            return
        }

        // Method Channel - 用于接收 Flutter 的命令
        let channel = FlutterMethodChannel(
            name: "com.nearlink/ble_advertise",
            binaryMessenger: controller.binaryMessenger
        )
        
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(false)
                return
            }
            
            switch call.method {
            case "startAdvertising":
                if let args = call.arguments as? [String: Any],
                   let deviceName = args["deviceName"] as? String {
                    let success = self.startAdvertising(deviceName: deviceName)
                    result(success)
                } else {
                    result(false)
                }
                
            case "stopAdvertising":
                self.stopAdvertising()
                result(true)

            case "disconnect":
                self.disconnect()
                result(true)
                
            case "sendData":
                // 发送数据到连接的中心设备
                if let args = call.arguments as? [String: Any],
                   let data = args["data"] as? FlutterStandardTypedData {
                    let success = self.sendDataToCentrals(data.data)
                    result(success)
                } else {
                    result(false)
                }

            case "sendDataBatch":
                // 批量发送数据（高性能版本）
                if let args = call.arguments as? [String: Any],
                   let packetsData = args["packets"] as? [[UInt8]] {
                    let packets = packetsData.map { Data($0) }
                    let success = self.sendDataBatch(packets)
                    result(success)
                } else {
                    result(false)
                }
                
            case "getConnectedCentralsCount":
                result(self.getConnectedCentralsCount())

            case "getPendingNotificationCount":
                result(self.getPendingNotificationCount())

            case "clearPendingNotifications":
                result(self.clearPendingNotifications())

            case "clearTransferBuffers":
                result(self.clearTransferBuffers())
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        // Event Channel - 用于向 Flutter 发送事件（连接状态变化）
        eventChannel = FlutterEventChannel(
            name: "com.nearlink/ble_advertise_events",
            binaryMessenger: controller.binaryMessenger
        )
        eventChannel?.setStreamHandler(self)
        channelsConfigured = true
    }
    
    // MARK: - FlutterStreamHandler
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events

        if pendingEvents.first(where: { ($0["event"] as? String) == "centralConnected" }) == nil {
            for central in connectedCentrals {
                events([
                    "event": "centralConnected",
                    "centralId": central.identifier.uuidString,
                    "mtu": central.maximumUpdateValueLength
                ])
            }
        }

        if !pendingEvents.isEmpty {
            for event in pendingEvents {
                events(event)
            }
            pendingEvents.removeAll()
        }
        
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
