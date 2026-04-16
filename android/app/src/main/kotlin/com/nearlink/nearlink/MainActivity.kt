package com.nearlink.nearlink

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.content.Context
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nearlink/ble_advertise"
    private val EVENT_CHANNEL = "com.nearlink/ble_advertise_events"
    
    private var bluetoothLeAdvertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false
    private var currentDeviceName: String = "NearLink"
    
    // GATT Server
    private var gattServer: BleGattServer? = null
    
    // Event Channel
    private var eventSink: EventChannel.EventSink? = null
    
    // 已连接的设备（用于发送数据）
    private var connectedDevice: BluetoothDevice? = null
    
    // NearLink 厂商 ID
    private val MANUFACTURER_ID = 0xFF01
    
    // NearLink 服务 UUID
    private val SERVICE_UUID = "0000FFFF-0000-1000-8000-00805F9B34FB"

    private fun emitEvent(event: Map<String, Any?>) {
        runOnUiThread {
            eventSink?.success(event)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        ensureGattServer()
        
        // 设置 Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertising" -> {
                    val deviceName = call.argument<String>("deviceName") ?: "NearLink"
                    val serviceUuid = call.argument<String>("serviceUuid") ?: SERVICE_UUID
                    
                    // 检查权限
                    if (!hasRequiredPermissions()) {
                        android.util.Log.e("NearLink", "缺少必要权限")
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    
                    ensureGattServer()

                    // 先启动 GATT Server（服务需要先添加完成）
                    val gattSuccess = gattServer?.startServer() ?: false
                    
                    // 等待服务添加完成后再启动广播
                    val advertiseSuccess = if (gattSuccess) {
                        startBleAdvertising(deviceName, serviceUuid)
                    } else {
                        false
                    }
                    
                    val success = advertiseSuccess && gattSuccess
                    android.util.Log.d("NearLink", "启动广播: $advertiseSuccess, 启动 GATT: $gattSuccess")
                    result.success(success)
                }
                "stopAdvertising" -> {
                    stopBleAdvertising()
                    // 注意：不要在这里关闭GATT服务器！GATT服务器需要在连接期间保持运行
                    // 只有在完全断开连接时才关闭GATT服务器
                    result.success(true)
                }
                "disconnect" -> {
                    // 断开当前连接，保留能力以便后续重新连接
                    stopBleAdvertising()
                    val disconnected = if (connectedDevice != null) {
                        gattServer?.disconnectDevice(connectedDevice!!) ?: false
                    } else {
                        true
                    }
                    connectedDevice = null
                    result.success(disconnected)
                }
                "sendData" -> {
                    // Android 作为 Peripheral 发送数据给中心设备
                    val data = call.argument<ByteArray>("data")
                    // android.util.Log.d("NearLink", "sendData 请求: dataSize=${data?.size}, connectedDevice=${connectedDevice?.address}")
                    if (data != null && connectedDevice != null) {
                        val success = gattServer?.sendData(connectedDevice!!, data) ?: false
                        // android.util.Log.d("NearLink", "sendData 结果: success=$success")
                        result.success(success)
                    } else {
                        // android.util.Log.w("NearLink", "sendData 失败: data=${data != null}, connectedDevice=${connectedDevice != null}")
                        result.success(false)
                    }
                }
                "getPendingNotificationCount" -> {
                    val pendingCount = if (connectedDevice != null) {
                        gattServer?.getPendingNotificationCount(connectedDevice!!) ?: 0
                    } else {
                        0
                    }
                    result.success(pendingCount)
                }
                "getConnectedCentralsCount" -> {
                    result.success(if (connectedDevice != null) 1 else 0)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // 设置 Event Channel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    android.util.Log.d("NearLink", "Flutter 开始监听事件")
                }
                
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    android.util.Log.d("NearLink", "Flutter 取消监听事件")
                }
            }
        )
    }
    
    private fun setupGattServerCallbacks() {
        // 设置 GATT Server 连接回调
        gattServer?.setConnectionCallback(object : BleGattServer.ConnectionCallback {
            override fun onDeviceConnected(device: BluetoothDevice) {
                android.util.Log.d("NearLink", "GATT 设备已连接: ${device.address}")
                connectedDevice = device
                
                emitEvent(
                    mapOf(
                        "event" to "centralConnected",
                        "centralId" to device.address,
                        "mtu" to 512
                    )
                )
            }
            
            override fun onDeviceDisconnected(device: BluetoothDevice) {
                android.util.Log.d("NearLink", "GATT 设备已断开: ${device.address}")
                if (connectedDevice?.address == device.address) {
                    connectedDevice = null
                }
                
                emitEvent(
                    mapOf(
                        "event" to "centralDisconnected",
                        "centralId" to device.address
                    )
                )
            }
            
            override fun onDataReceived(device: BluetoothDevice, data: ByteArray) {
                emitEvent(
                    mapOf(
                        "event" to "dataReceived",
                        "centralId" to device.address,
                        "data" to data
                    )
                )
            }
        })
    }
    
    private fun hasRequiredPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val advertiseGranted = ContextCompat.checkSelfPermission(this, android.Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
            val connectGranted = ContextCompat.checkSelfPermission(this, android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            val scanGranted = ContextCompat.checkSelfPermission(this, android.Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            
            advertiseGranted && connectGranted && scanGranted
        } else {
            true
        }
    }

    private fun ensureGattServer() {
        if (gattServer == null) {
            gattServer = BleGattServer(this)
            setupGattServerCallbacks()
        }
    }

    private fun startBleAdvertising(deviceName: String, serviceUuid: String): Boolean {
        if (isAdvertising) return true
        
        currentDeviceName = deviceName
        android.util.Log.d("NearLink", "开始 BLE 广播, 设备名称: $deviceName")

        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter = bluetoothManager.adapter
        
        if (!bluetoothAdapter.isEnabled) {
            android.util.Log.e("NearLink", "蓝牙未开启")
            return false
        }
        
        bluetoothLeAdvertiser = bluetoothAdapter.bluetoothLeAdvertiser

        if (bluetoothLeAdvertiser == null) {
            android.util.Log.e("NearLink", "设备不支持 BLE 广播")
            return false
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0) // 不设置超时，由应用控制
            .build()

        // 精简广播数据：只使用服务 UUID，避免超出 31 字节限制
        // 设备名称通过 GATT 服务获取，不放在广播包中
        
        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)  // 不包含设备名称，节省空间
            .addServiceUuid(ParcelUuid.fromString(serviceUuid))  // 只广播服务 UUID（关键！）
            // 可选：添加简短的 Manufacturer Data 用于标识 NearLink
            // .addManufacturerData(MANUFACTURER_ID, byteArrayOf('N'.code.toByte(), 'L'.code.toByte()))

        try {
            bluetoothLeAdvertiser?.startAdvertising(settings, dataBuilder.build(), advertiseCallback)
            isAdvertising = true
            android.util.Log.d("NearLink", "BLE 广播已启动 (包含 Service UUID: $serviceUuid)")
            emitEvent(mapOf("event" to "advertisingStarted"))
            return true
        } catch (e: SecurityException) {
            android.util.Log.e("NearLink", "广播权限不足: ${e.message}")
            return false
        } catch (e: IllegalArgumentException) {
            android.util.Log.e("NearLink", "广播数据格式错误: ${e.message}")
            return false
        }
    }

    private fun stopBleAdvertising() {
        if (!isAdvertising) return
        
        try {
            bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            android.util.Log.d("NearLink", "BLE 广播已停止")
        } catch (e: SecurityException) {
            android.util.Log.e("NearLink", "停止广播权限不足: ${e.message}")
        }
        isAdvertising = false
        emitEvent(mapOf("event" to "advertisingStopped"))
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            super.onStartSuccess(settingsInEffect)
            android.util.Log.d("NearLink", "BLE 广播启动成功")
        }

        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            val errorMsg = when(errorCode) {
                ADVERTISE_FAILED_ALREADY_STARTED -> "已经正在广播"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "不支持广播"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "内部错误"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "广播器数量超限"
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "广播数据过大"
                else -> "未知错误: $errorCode"
            }
            android.util.Log.e("NearLink", "BLE 广播启动失败: $errorMsg")
            isAdvertising = false
        }
    }

    override fun onDestroy() {
        stopBleAdvertising()
        gattServer?.stopServer()
        super.onDestroy()
    }
}
