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
    
    // 数据包重组缓冲区
    private var reassemblyBuffer: Data = Data()
    
    // NearLink 包头部大小
    private let nearlinkHeaderSize = 64
    
    static let shared = BleAdvertiser()
    
    private override init() {
        super.init()
        // 初始化外围设备管理器
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
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
        // 合并所有请求的数据
        var combinedData = Data()
        for request in requests {
            if let value = request.value {
                combinedData.append(value)
            }
        }
        
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
            
            // 转发给 Flutter
            if let sink = eventSink {
                let eventData: [String: Any] = [
                    "event": "dataReceived",
                    "characteristicUuid": "0000FF02-0000-1000-8000-00805F9B34FB",
                    "data": FlutterStandardTypedData(bytes: packet)
                ]
                sink(eventData)
            }
            
            // 如果缓冲区还有数据，递归处理
            if reassemblyBuffer.count >= nearlinkHeaderSize {
                processReassemblyBuffer()
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("[BleAdvertiser] didSubscribeTo: central=\(central.identifier.uuidString), char=\(characteristic.uuid)")
        
        // 记录连接的中心设备
        if !connectedCentrals.contains(where: { $0.identifier == central.identifier }) {
            connectedCentrals.append(central)
            print("[BleAdvertiser] didSubscribeTo: added central to connectedCentrals (total: \(connectedCentrals.count))")
        }
        
        // 停止广播（有设备连接后不再广播）
        if isAdvertising {
            stopAdvertising()
            print("[BleAdvertiser] didSubscribeTo: stopped advertising")
        }
        
        // 存储协商的 MTU
        negotiatedMtu = central.maximumUpdateValueLength
        print("[BleAdvertiser] didSubscribeTo: negotiated MTU = \(negotiatedMtu)")
        
        // 通知 Flutter 有设备连接
        let eventData: [String: Any] = [
            "event": "centralConnected",
            "centralId": central.identifier.uuidString,
            "mtu": negotiatedMtu
        ]
        eventSink?(eventData)
        print("[BleAdvertiser] didSubscribeTo: sent centralConnected event to Flutter (pending queue: \(pendingDataQueue.count))")
        
        // 发送队列中的所有待处理数据
        flushPendingDataQueue()
    }
    
    /// 发送队列中的所有待处理数据
    private func flushPendingDataQueue() {
        print("[BleAdvertiser] flushPendingDataQueue: queue size = \(pendingDataQueue.count)")
        while !pendingDataQueue.isEmpty {
            let data = pendingDataQueue.removeFirst()
            if !sendDataToCentrals(data) {
                // 发送队列满了，停止发送（数据会继续在队列中）
                print("[BleAdvertiser] flushPendingDataQueue: send failed, stopping flush")
                break
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        // 注意：取消订阅不等于断开连接，只是设备暂时不需要通知
        // 不要移除设备，也不要通知断开，只记录日志
        print("[BleAdvertiser] 中心设备 \(central.identifier.uuidString) 取消订阅，等待重新订阅...")
        
        // 不移除设备，因为它仍然连接着，只是暂时取消订阅
        // 当设备重新订阅时，didSubscribeTo 会被调用
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didDisconnectCentral central: CBCentral, error: Error?) {
        // 完全断开连接时调用（iOS 11+）
        print("[BleAdvertiser] 中心设备完全断开: \(central.identifier.uuidString), error: \(error?.localizedDescription ?? "none")")
        
        // 移除断开的设备
        connectedCentrals.removeAll { $0.identifier == central.identifier }
        
        // 通知 Flutter 设备断开
        let eventData: [String: Any] = [
            "event": "centralDisconnected",
            "centralId": central.identifier.uuidString
        ]
        eventSink?(eventData)
        
        // 如果仍然有其他连接的设备，不需要重新广播
        if !connectedCentrals.isEmpty {
            print("[BleAdvertiser] 仍有 \(connectedCentrals.count) 个设备连接，不重新广播")
            return
        }
        
        // 所有设备都断开了，自动重新开始广播以便接收新的连接
        // 这样用户不需要手动重新开启广播
        if peripheralManager?.state == .poweredOn && !isAdvertising {
            print("[BleAdvertiser] 自动重新开始广播")
            startAdvertising(deviceName: pendingDeviceName)
        }
    }
    
    /// 发送数据到已连接的中心设备
    /// 数据会自动分块发送以适应 MTU
    func sendDataToCentrals(_ data: Data) -> Bool {
        guard let txChar = txCharacteristic else {
            print("[BleAdvertiser] sendDataToCentrals: txCharacteristic is nil")
            return false
        }
        
        // 检查是否有已连接的中心设备
        if connectedCentrals.isEmpty {
            print("[BleAdvertiser] sendDataToCentrals: no connected centrals, queueing data")
            pendingDataQueue.append(data)
            return false
        }
        
        let subscribers = txChar.subscribedCentrals
        if subscribers == nil || subscribers!.isEmpty {
            print("[BleAdvertiser] sendDataToCentrals: no subscribers to TX char, queueing data")
            pendingDataQueue.append(data)
            // 即使没有订阅者，也返回 true 表示数据已入队
            // 数据会在 Android 订阅后通过 didSubscribeTo -> flushPendingDataQueue 发送
            return true
        }
        
        // 检查蓝牙是否开启
        if peripheralManager?.state != .poweredOn {
            print("[BleAdvertiser] sendDataToCentrals: not powered on, queueing data")
            pendingDataQueue.append(data)
            return false
        }
        
        // 发送给所有订阅了该特征值的中心设备
        // CoreBluetooth 会自动处理分块
        let didSend = peripheralManager?.updateValue(data, for: txChar, onSubscribedCentrals: nil) ?? false
        
        if !didSend {
            print("[BleAdvertiser] sendDataToCentrals: updateValue returned false, queueing data")
            pendingDataQueue.append(data)
            // 返回 true 表示数据已入队，等待 peripheralManagerIsReady 发送
            return true
        }
        
        return true
    }
    
    /// 获取已连接的中心设备数量
    func getConnectedCentralsCount() -> Int {
        return connectedCentrals.count
    }
    
    // MARK: - 连接状态监听
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // 发送队列中的所有待处理数据
        print("[BleAdvertiser] peripheralManagerIsReady: ready to send more data")
        flushPendingDataQueue()
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
                
            case "sendData":
                // 发送数据到连接的中心设备
                if let args = call.arguments as? [String: Any],
                   let data = args["data"] as? FlutterStandardTypedData {
                    let success = self.sendDataToCentrals(data.data)
                    result(success)
                } else {
                    result(false)
                }
                
            case "getConnectedCentralsCount":
                result(self.getConnectedCentralsCount())
                
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
    }
    
    // MARK: - FlutterStreamHandler
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        
        // 如果队列中有数据，立即发送
        if !pendingDataQueue.isEmpty {
            while !pendingDataQueue.isEmpty {
                let data = pendingDataQueue.removeFirst()
                let eventData: [String: Any] = [
                    "event": "dataReceived",
                    "characteristicUuid": rxCharacteristic?.uuid.uuidString ?? "unknown",
                    "data": data
                ]
                events(eventData)
            }
        }
        
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
