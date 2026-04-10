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
    
    // 已订阅通知的设备（订阅了TX特征值）
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()
    
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
            
            // 创建 TX 特征值（Notify）- 用于发送数据给中心设备
            val txChar = BluetoothGattCharacteristic(
                CHAR_TX_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            // 添加 CCCD 描述符（通知必需）
            val txDescriptor = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            txChar.addDescriptor(txDescriptor)
            
            // 创建 RX 特征值（Write）- 用于接收中心设备的数据
            val rxChar = BluetoothGattCharacteristic(
                CHAR_RX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
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
            Log.d(TAG, "GATT Server 已停止")
        } catch (e: Exception) {
            Log.e(TAG, "停止 GATT Server 失败: ${e.message}")
        }
        
        isServerRunning = false
        gattServer = null
    }
    
    /**
     * 发送数据给已连接的设备
     */
    fun sendData(device: BluetoothDevice, data: ByteArray): Boolean {
        if (!connectedDevices.contains(device)) {
            return false
        }
        
        val service = gattServer?.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(CHAR_TX_UUID)
        
        if (characteristic == null) {
            return false
        }
        
        characteristic.value = data
        try {
            return gattServer?.notifyCharacteristicChanged(device, characteristic, false) ?: false
        } catch (e: SecurityException) {
            return false
        }
    }
    
    /**
     * 发送数据给所有订阅通知的设备
     */
    fun sendDataToAllSubscribers(data: ByteArray): Boolean {
        if (subscribedDevices.isEmpty()) {
            return false
        }
        
        val service = gattServer?.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(CHAR_TX_UUID)
        
        if (characteristic == null) {
            return false
        }
        
        var allSuccess = true
        for (device in subscribedDevices.toList()) {
            if (connectedDevices.contains(device)) {
                characteristic.value = data
                try {
                    val success = gattServer?.notifyCharacteristicChanged(device, characteristic, false) ?: false
                    if (!success) {
                        allSuccess = false
                    }
                } catch (e: SecurityException) {
                    allSuccess = false
                }
            } else {
                subscribedDevices.remove(device)
            }
        }
        
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
                    // 关键检查：服务是否已添加
                    if (!isServiceAdded) {
                        Log.w(TAG, "服务尚未添加完成，断开设备: ${device?.address}")
                        // 拒绝连接，让设备稍后重连
                        try {
                            gattServer?.cancelConnection(device)
                        } catch (e: SecurityException) {
                            Log.e(TAG, "断开连接权限不足: ${e.message}")
                        }
                        return
                    }
                    
                    Log.d(TAG, "设备已连接: ${device?.address}")
                    device?.let { 
                        connectedDevices.add(it)
                        connectionCallback?.onDeviceConnected(it)
                    }
                }
                BluetoothGatt.STATE_DISCONNECTED -> {
                    Log.d(TAG, "设备已断开: ${device?.address}")
                    device?.let { 
                        connectedDevices.remove(it)
                        subscribedDevices.remove(it)  // 清理订阅状态
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
            if (descriptor != null && value != null && device != null) {
                descriptor.value = value
                
                // 检查是否是CCCD描述符（用于通知订阅）
                val isCCCD = descriptor.uuid.toString().equals(CCCD_UUID.toString(), ignoreCase = true)
                val isTXCharacteristic = descriptor.characteristic?.uuid?.toString()?.equals(CHAR_TX_UUID.toString(), ignoreCase = true) == true
                
                if (isCCCD && isTXCharacteristic) {
                    // 检查是否启用通知（0x0001 = 启用，0x0000 = 禁用）
                    val enableNotify = value.size >= 2 && (value[0].toInt() and 0x01) == 0x01
                    
                    if (enableNotify) {
                        subscribedDevices.add(device)
                    } else {
                        subscribedDevices.remove(device)
                    }
                }
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
        
        override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
            // 通知发送完成，无需处理
        }
        
        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            Log.d(TAG, "MTU 变更: $mtu")
        }
    }
}
