package com.nearlink.nearlink

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import java.util.ArrayDeque
import java.util.UUID

/**
 * NearLink BLE GATT Server
 * 让 Android 作为外围设备，可以被 iOS 连接
 */
class BleGattServer(private val context: Context) {
    
    private var bluetoothManager: BluetoothManager? = null
    private var gattServer: BluetoothGattServer? = null
    private var isServerRunning = false
    
    // NearLink 服务 UUID
    private val SERVICE_UUID = UUID.fromString("0000FFFF-0000-1000-8000-00805F9B34FB")
    private val CHAR_TX_UUID = UUID.fromString("0000FF01-0000-1000-8000-00805F9B34FB")
    private val CHAR_RX_UUID = UUID.fromString("0000FF02-0000-1000-8000-00805F9B34FB")
    private val CHAR_NOTIFY_UUID = UUID.fromString("0000FF03-0000-1000-8000-00805F9B34FB")
    
    // CCCD 描述符 UUID（用于通知）
    private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    
    // 已连接的设备
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    private val deviceMtuMap = mutableMapOf<String, Int>()
    
    // 已订阅通知的设备（订阅了TX特征值）
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()
    private val pendingNotifications = mutableMapOf<String, ArrayDeque<ByteArray>>()
    private val notificationInFlight = mutableSetOf<String>()
    private val notificationRetryCounts = mutableMapOf<String, Int>()
    
    // 服务添加完成信号量
    private var serviceAddLatch: java.util.concurrent.CountDownLatch? = null
    private var isServiceAdded = false
    
    // 连接回调
    interface ConnectionCallback {
        fun onDeviceConnected(device: BluetoothDevice)
        fun onDeviceDisconnected(device: BluetoothDevice)
        fun onDataReceived(device: BluetoothDevice, data: ByteArray)
    }
    
    private var connectionCallback: ConnectionCallback? = null
    
    companion object {
        private const val TAG = "NearLink-GATT"
        private const val MAX_NOTIFICATION_RETRY = 3
        private const val MAX_NOTIFY_ATTRIBUTE_VALUE = 500
    }
    
    /**
     * ByteArray 扩展函数，转换为十六进制字符串
     */
    private fun ByteArray.toHexString(): String {
        return joinToString("") { "%02X".format(it) }
    }
    
    init {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        // 确保初始状态：服务未添加
        isServiceAdded = false
    }
    
    fun setConnectionCallback(callback: ConnectionCallback) {
        connectionCallback = callback
    }

    fun isRunning(): Boolean {
        return isServerRunning
    }
    
    /**
     * 启动 GATT Server
     */
    fun startServer(): Boolean {
        if (isServerRunning) {
            Log.d(TAG, "GATT Server 已在运行")
            return true
        }
        
        val bluetoothAdapter = bluetoothManager?.adapter
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "蓝牙未开启")
            return false
        }
        
        // Android 12+ 需要 BLUETOOTH_CONNECT 权限
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            val hasPermission = androidx.core.content.ContextCompat.checkSelfPermission(
                context, 
                android.Manifest.permission.BLUETOOTH_CONNECT
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            
            if (!hasPermission) {
                Log.e(TAG, "缺少 BLUETOOTH_CONNECT 权限")
                return false
            }
        }
        
        try {
            Log.d(TAG, "正在打开 GATT Server...")
            gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)
            
            if (gattServer == null) {
                Log.e(TAG, "无法打开 GATT Server")
                return false
            }
            Log.d(TAG, "GATT Server 已打开")
            
            // 重置服务添加状态
            isServiceAdded = false
            serviceAddLatch = java.util.concurrent.CountDownLatch(1)
            
            // 创建 NearLink 服务
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            
            // 创建 TX 特征值（Notify + WriteWithoutResponse）- 用于发送数据给中心设备，也支持中心设备写入
            val txChar = BluetoothGattCharacteristic(
                CHAR_TX_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            // 添加 CCCD 描述符（通知必需）
            val txDescriptor = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            txChar.addDescriptor(txDescriptor)

            // 创建 RX 特征值（Write + WriteNoResponse）- 用于接收中心设备的数据
            val rxChar = BluetoothGattCharacteristic(
                CHAR_RX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            
            // 添加特征值到服务
            service.addCharacteristic(txChar)
            service.addCharacteristic(rxChar)
            
            // 添加服务到 GATT Server（异步）
            val addRequested = gattServer?.addService(service) ?: false
            
            if (!addRequested) {
                Log.e(TAG, "请求添加服务失败")
                return false
            }
            
            // 等待服务添加完成（最多等待5秒）
            Log.d(TAG, "等待服务添加完成...")
            val added = serviceAddLatch?.await(5, java.util.concurrent.TimeUnit.SECONDS) ?: false
            
            if (added && isServiceAdded) {
                isServerRunning = true
                Log.d(TAG, "GATT Server 启动成功，服务已添加")
                return true
            } else {
                Log.e(TAG, "服务添加超时或失败")
                return false
            }
            
        } catch (e: SecurityException) {
            Log.e(TAG, "启动 GATT Server 权限不足: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "启动 GATT Server 失败: ${e.message}")
            return false
        }
    }
    
    /**
     * 停止 GATT Server
     */
    fun stopServer() {
        if (!isServerRunning) return
        
        try {
            gattServer?.close()
            connectedDevices.clear()
            subscribedDevices.clear()
            deviceMtuMap.clear()
            pendingNotifications.clear()
            notificationInFlight.clear()
            notificationRetryCounts.clear()
            Log.d(TAG, "GATT Server 已停止")
        } catch (e: Exception) {
            Log.e(TAG, "停止 GATT Server 失败: ${e.message}")
        }
        
        isServerRunning = false
        gattServer = null
    }

    /**
     * 断开指定设备，但保留 GATT Server 运行，以便后续重新连接
     */
    fun disconnectDevice(device: BluetoothDevice): Boolean {
        val server = gattServer ?: return false

        return try {
            clearNotificationState(device)
            server.cancelConnection(device)
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "断开设备权限不足: ${e.message}")
            false
        } catch (e: Exception) {
            Log.e(TAG, "断开设备失败: ${e.message}")
            false
        }
    }
    
    /**
     * 发送数据给已连接的设备
     */
    fun sendData(device: BluetoothDevice, data: ByteArray): Boolean {
        if (!connectedDevices.contains(device)) {
            return false
        }

        val mtu = deviceMtuMap[device.address] ?: 185
        val maxNotifySize = minOf(MAX_NOTIFY_ATTRIBUTE_VALUE, maxOf(20, mtu - 3))

        try {
            val queue = pendingNotifications.getOrPut(device.address) { ArrayDeque() }
            enqueueNotificationFragments(queue, data, maxNotifySize)

            if (notificationInFlight.contains(device.address)) {
                return true
            }

            val started = sendNextNotification(device)
            if (!started) {
                clearNotificationState(device)
                Log.w(TAG, "通知发送失败: device=${device.address}, mtu=$mtu")
            }
            return started
        } catch (e: SecurityException) {
            return false
        }
    }

    fun sendDataBatch(device: BluetoothDevice, packets: List<ByteArray>): Boolean {
        if (!connectedDevices.contains(device)) {
            return false
        }

        if (packets.isEmpty()) {
            return true
        }

        val mtu = deviceMtuMap[device.address] ?: 185
        val maxNotifySize = minOf(MAX_NOTIFY_ATTRIBUTE_VALUE, maxOf(20, mtu - 3))

        try {
            val queue = pendingNotifications.getOrPut(device.address) { ArrayDeque() }
            for (packet in packets) {
                enqueueNotificationFragments(queue, packet, maxNotifySize)
            }

            if (notificationInFlight.contains(device.address)) {
                return true
            }

            val started = sendNextNotification(device)
            if (!started) {
                clearNotificationState(device)
                Log.w(TAG, "批量通知发送失败: device=${device.address}, mtu=$mtu, packets=${packets.size}")
            }
            return started
        } catch (e: SecurityException) {
            return false
        }
    }

    fun getPendingNotificationCount(device: BluetoothDevice): Int {
        val queue = pendingNotifications[device.address]
        return queue?.size ?: 0
    }

    fun clearPendingNotifications(device: BluetoothDevice): Boolean {
        return try {
            clearNotificationState(device)
            true
        } catch (e: Exception) {
            Log.e(TAG, "清空待发送通知队列失败: ${e.message}")
            false
        }
    }

    fun clearTransferBuffers(device: BluetoothDevice): Boolean {
        return try {
            clearNotificationState(device)
            true
        } catch (e: Exception) {
            Log.e(TAG, "清空传输缓冲失败: ${e.message}")
            false
        }
    }

    private fun enqueueNotificationFragments(
        queue: ArrayDeque<ByteArray>,
        data: ByteArray,
        maxNotifySize: Int
    ) {
        var offset = 0
        while (offset < data.size) {
            val end = minOf(offset + maxNotifySize, data.size)
            queue.addLast(data.copyOfRange(offset, end))
            offset = end
        }
    }

    private fun sendNextNotification(device: BluetoothDevice): Boolean {
        val server = gattServer ?: return false
        val service = server.getService(SERVICE_UUID) ?: return false
        val characteristic = service.getCharacteristic(CHAR_TX_UUID) ?: return false
        val queue = pendingNotifications[device.address] ?: return false
        val nextChunk = queue.firstOrNull() ?: return true

        characteristic.value = nextChunk
        val notified = try {
            server.notifyCharacteristicChanged(device, characteristic, false)
        } catch (e: SecurityException) {
            false
        }

        if (notified) {
            notificationInFlight.add(device.address)
        }
        return notified
    }

    private fun clearNotificationState(device: BluetoothDevice) {
        pendingNotifications.remove(device.address)
        notificationInFlight.remove(device.address)
        notificationRetryCounts.remove(device.address)
    }
    
    /**
     * 发送数据给所有订阅通知的设备
     */
    fun sendDataToAllSubscribers(data: ByteArray): Boolean {
        Log.d(TAG, "发送数据给所有订阅者: dataSize=${data.size}, 订阅设备数=${subscribedDevices.size}, 连接设备数=${connectedDevices.size}")

        if (subscribedDevices.isEmpty()) {
            Log.w(TAG, "没有设备订阅通知，无法发送数据")
            return false
        }

        val service = gattServer?.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(CHAR_TX_UUID)

        if (characteristic == null) {
            Log.e(TAG, "无法获取 TX 特征值，无法发送数据")
            return false
        }

        var allSuccess = true
        var sentCount = 0
        for (device in subscribedDevices.toList()) {
            if (connectedDevices.contains(device)) {
                characteristic.value = data
                try {
                    val success = gattServer?.notifyCharacteristicChanged(device, characteristic, false) ?: false
                    if (success) {
                        sentCount++
                    } else {
                        allSuccess = false
                        Log.w(TAG, "通知发送失败: ${device.address}")
                    }
                } catch (e: SecurityException) {
                    allSuccess = false
                    Log.e(TAG, "发送通知权限不足: ${e.message}")
                }
            } else {
                Log.w(TAG, "设备已断开，从订阅列表移除: ${device.address}")
                subscribedDevices.remove(device)
            }
        }

        Log.d(TAG, "数据发送完成: 成功=$sentCount, 全部成功=$allSuccess")
        return allSuccess
    }
    
    /**
     * GATT Server 回调
     */
    private val gattServerCallback = object : BluetoothGattServerCallback() {
        
        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            Log.d(TAG, "GATT 连接状态变化: device=${device?.address}, status=$status, newState=$newState")
            when (newState) {
                BluetoothGatt.STATE_CONNECTED -> {
                    Log.d(TAG, "设备已连接: ${device?.address}")
                    device?.let {
                        connectedDevices.add(it)
                        deviceMtuMap[it.address] = 185
                        if (!isServiceAdded) {
                            Log.d(TAG, "服务尚未添加完成，保留连接等待服务就绪: ${it.address}")
                        } else {
                            // 注意：不要在这里调用 onDeviceConnected！
                            // 等待设备订阅 TX 特征值通知后再通知 Flutter（与 iOS 行为一致）
                            Log.d(TAG, "设备已连接，等待订阅 TX 特征值...")
                        }
                    }
                }
                BluetoothGatt.STATE_DISCONNECTED -> {
                    Log.d(TAG, "设备已断开: ${device?.address}")
                    device?.let {
                        connectedDevices.remove(it)
                        deviceMtuMap.remove(it.address)
                        subscribedDevices.remove(it)
                        clearNotificationState(it)
                        connectionCallback?.onDeviceDisconnected(it)
                    }
                }
            }
        }
        
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "服务添加成功: ${service?.uuid}")
                isServiceAdded = true
                serviceAddLatch?.countDown()
            } else {
                Log.e(TAG, "服务添加失败，状态: $status")
                isServiceAdded = false
                serviceAddLatch?.countDown()
            }
        }
        
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice?,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic?
        ) {
            Log.d(TAG, "收到读请求: ${characteristic?.uuid}")
            
            try {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    characteristic?.value
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "响应读请求权限不足")
            }
        }
        
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            // 如果是 RX 特征值，转发数据到 Flutter
            if (characteristic?.uuid == CHAR_RX_UUID && value != null && device != null) {
                connectionCallback?.onDataReceived(device, value)
            }
            
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        null
                    )
                } catch (e: SecurityException) {
                    // 忽略
                }
            }
        }
        
        override fun onDescriptorReadRequest(
            device: BluetoothDevice?,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor?
        ) {
            Log.d(TAG, "收到描述符读请求: ${descriptor?.uuid}")
            
            try {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    descriptor?.value
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "响应描述符读请求权限不足")
            }
        }
        
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            Log.d(TAG, "收到描述符写入请求: device=${device?.address}, descriptor=${descriptor?.uuid}, value=${value?.toHexString()}")

            if (descriptor != null && value != null && device != null) {
                descriptor.value = value

                // 检查是否是CCCD描述符（用于通知订阅）
                val isCCCD = descriptor.uuid.toString().equals(CCCD_UUID.toString(), ignoreCase = true)
                val charUuid = descriptor.characteristic?.uuid?.toString()?.uppercase() ?: ""
                val isTXCharacteristic = charUuid.equals(CHAR_TX_UUID.toString(), ignoreCase = true) ||
                                         charUuid.contains("FF01")

                Log.d(TAG, "描述符写入: isCCCD=$isCCCD, isTXCharacteristic=$isTXCharacteristic, charUuid=$charUuid")

                if (isCCCD) {
                    // 检查是否启用通知（0x0001 = 启用，0x0000 = 禁用）
                    val enableNotify = value.size >= 2 && (value[0].toInt() and 0x01) == 0x01

                    Log.d(TAG, "CCCD写入: enableNotify=$enableNotify, value=${value.toHexString()}")

                    if (enableNotify) {
                        val isNewSubscription = !subscribedDevices.contains(device)
                        subscribedDevices.add(device)
                        Log.d(TAG, "设备已订阅通知: ${device.address}, 总订阅数: ${subscribedDevices.size}")

                        // 首次订阅时通知 Flutter（与 iOS 行为一致）
                        if (isNewSubscription) {
                            Log.d(TAG, "首次订阅 TX 特征值，通知 Flutter 设备已连接")
                            connectionCallback?.onDeviceConnected(device)
                        }
                    } else {
                        subscribedDevices.remove(device)
                        Log.d(TAG, "设备已取消订阅: ${device.address}, 总订阅数: ${subscribedDevices.size}")
                    }
                }
            }

            if (responseNeeded) {
                try {
                    val success = gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        null
                    ) ?: false
                    Log.d(TAG, "描述符写入响应: success=$success")
                } catch (e: SecurityException) {
                    Log.e(TAG, "响应描述符写入权限不足: ${e.message}")
                }
            }
        }
        
        override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
            val targetDevice = device ?: return
            val address = targetDevice.address

            if (status == BluetoothGatt.GATT_SUCCESS) {
                pendingNotifications[address]?.let { queue ->
                    if (queue.isNotEmpty()) {
                        queue.removeFirst()
                    }
                }
                notificationRetryCounts.remove(address)

                val queue = pendingNotifications[address]
                if (queue.isNullOrEmpty()) {
                    clearNotificationState(targetDevice)
                    return
                }

                if (!sendNextNotification(targetDevice)) {
                    clearNotificationState(targetDevice)
                }
                return
            }

            val retryCount = (notificationRetryCounts[address] ?: 0) + 1
            notificationRetryCounts[address] = retryCount

            if (retryCount <= MAX_NOTIFICATION_RETRY && sendNextNotification(targetDevice)) {
                return
            }

            Log.w(TAG, "通知发送失败，已放弃: ${targetDevice.address}, status=$status")
            clearNotificationState(targetDevice)
        }
        
        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            Log.d(TAG, "MTU 变更: $mtu")
            device?.let {
                deviceMtuMap[it.address] = mtu
            }
        }
    }
}
