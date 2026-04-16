import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        setupBleMethodChannelIfNeeded()
    }

    override func sceneDidBecomeActive(_ scene: UIScene) {
        super.sceneDidBecomeActive(scene)
        setupBleMethodChannelIfNeeded()
    }

    private func setupBleMethodChannelIfNeeded() {
        if let flutterViewController = window?.rootViewController as? FlutterViewController {
            BleAdvertiser.shared.setupMethodChannel(with: flutterViewController)
        }
    }
}
