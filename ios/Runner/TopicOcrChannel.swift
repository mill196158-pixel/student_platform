import Flutter
import UIKit
import Vision

/// On-device topic-list OCR via Apple Vision.
/// App deployment target stays iOS 15; Russian OCR requires iOS 16+ at runtime.
enum TopicOcrChannel {
  static let name = "student_platform/topic_ocr"

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "recognize":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          !path.isEmpty
        else {
          result(
            FlutterError(
              code: "bad_args",
              message: "Путь к изображению не передан.",
              details: nil
            )
          )
          return
        }
        recognize(path: path, result: result)
      case "isAvailable":
        result(isRussianVisionAvailable())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Vision Russian recognition languages are available from iOS 16.
  private static func isRussianVisionAvailable() -> Bool {
    if #available(iOS 16.0, *) {
      return true
    }
    return false
  }

  private static func recognize(path: String, result: @escaping FlutterResult) {
    guard isRussianVisionAvailable() else {
      result(
        FlutterError(
          code: "unsupported_os",
          message:
            "Распознавание кириллицы с фото доступно на iOS 16 и новее. "
            + "Введите темы вручную или выберите Excel/Word/PDF.",
          details: nil
        )
      )
      return
    }

    guard FileManager.default.fileExists(atPath: path) else {
      result(
        FlutterError(
          code: "missing_file",
          message: "Файл изображения не найден.",
          details: nil
        )
      )
      return
    }
    guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage
    else {
      result(
        FlutterError(
          code: "bad_image",
          message: "Не удалось открыть изображение.",
          details: nil
        )
      )
      return
    }

    if #available(iOS 16.0, *) {
      let request = VNRecognizeTextRequest { request, error in
        if let error = error {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "vision_error",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
          return
        }
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        let lines = observations.compactMap {
          $0.topCandidates(1).first?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        DispatchQueue.main.async {
          result(lines.joined(separator: "\n"))
        }
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["ru-RU", "en-US"]
      request.automaticallyDetectsLanguage = true

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try handler.perform([request])
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "vision_error",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
    }
  }
}
