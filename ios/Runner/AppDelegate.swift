import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 首先调用父类方法，这会初始化 Flutter 引擎和 window
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        
        // 注册 Flutter 插件
        GeneratedPluginRegistrant.register(with: self)
        
        // 设置 BLE 广播的 Method Channel
        setupBleMethodChannel()
        
        return result
    }
    
    private func setupBleMethodChannel() {
        // 尝试获取 FlutterViewController
        if let rootViewController = findFlutterViewController() {
            BleAdvertiser.shared.setupMethodChannel(with: rootViewController)
            return
        }
        
        // 延迟重试，最多尝试 10 次
        var attempts = 0
        func trySetup() {
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempts) * 0.5) { [weak self] in
                guard let self = self else { return }
                
                if let rootViewController = self.findFlutterViewController() {
                    BleAdvertiser.shared.setupMethodChannel(with: rootViewController)
                } else if attempts < 10 {
                    trySetup()
                }
            }
        }
        trySetup()
    }

    private func findFlutterViewController() -> FlutterViewController? {
        // 尝试多种方式获取 FlutterViewController
        if let rootViewController = window?.rootViewController as? FlutterViewController {
            return rootViewController
        }
        
        // 尝试通过 keyWindow 获取
        if let keyWindow = UIApplication.shared.keyWindow,
           let rootViewController = keyWindow.rootViewController as? FlutterViewController {
            return rootViewController
        }
        
        // 尝试通过 windows 数组获取
        for (_, window) in UIApplication.shared.windows.enumerated() {
            if let rootViewController = window.rootViewController as? FlutterViewController {
                return rootViewController
            }
        }
        
        return nil
    }
}
