import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      let storage = FlutterMethodChannel(
        name: "student_platform/storage_space", binaryMessenger: controller.binaryMessenger
      )
      storage.setMethodCallHandler { call, result in
        guard call.method == "availableSupportBytes" else {
          result(FlutterMethodNotImplemented); return
        }
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity, bytes > 0 else {
          result(nil); return
        }
        result(bytes)
      }
      let channel = FlutterMethodChannel(
        name: "student_platform/notifications",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        if call.method == "openNotificationSettings" {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
          }
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      TopicOcrChannel.register(with: controller)
    }

    return ok
  }
}
