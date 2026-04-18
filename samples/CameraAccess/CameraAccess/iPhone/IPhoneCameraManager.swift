import AVFoundation
import UIKit

enum IPhoneCameraError: LocalizedError {
  case sessionNotRunning
  case captureAlreadyInProgress
  case noPhotoData
  case cancelled

  var errorDescription: String? {
    switch self {
    case .sessionNotRunning:
      return "The iPhone camera is not running."
    case .captureAlreadyInProgress:
      return "A photo capture is already in progress."
    case .noPhotoData:
      return "The iPhone camera returned no photo data."
    case .cancelled:
      return "The iPhone photo capture was cancelled."
    }
  }
}

class IPhoneCameraManager: NSObject {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private let context = CIContext()
  private var isRunning = false
  private var pendingPhotoCaptureContinuation: CheckedContinuation<Data, Error>?

  var onFrameCaptured: ((UIImage) -> Void)?

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.captureSession.stopRunning()
      self?.isRunning = false
    }
  }

  private func configureSession() {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = .medium

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    if captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    NSLog("[iPhoneCamera] Session configured")
  }

  func capturePhoto() async throws -> Data {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Data, Error>) in
          guard let self else {
            continuation.resume(throwing: IPhoneCameraError.cancelled)
            return
          }

          self.sessionQueue.async {
            guard self.isRunning else {
              continuation.resume(throwing: IPhoneCameraError.sessionNotRunning)
              return
            }
            guard self.pendingPhotoCaptureContinuation == nil else {
              continuation.resume(throwing: IPhoneCameraError.captureAlreadyInProgress)
              return
            }

            self.pendingPhotoCaptureContinuation = continuation

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
              connection.videoRotationAngle = 90
            }

            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
          }
        }
      },
      onCancel: { [weak self] in
        self?.finishPhotoCapture(with: .failure(IPhoneCameraError.cancelled))
      }
    )
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)

    onFrameCaptured?(image)
  }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension IPhoneCameraManager: AVCapturePhotoCaptureDelegate {
  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error {
      finishPhotoCapture(with: .failure(error))
      return
    }

    guard let data = photo.fileDataRepresentation() else {
      finishPhotoCapture(with: .failure(IPhoneCameraError.noPhotoData))
      return
    }

    finishPhotoCapture(with: .success(data))
  }
}

private extension IPhoneCameraManager {
  func finishPhotoCapture(with result: Result<Data, Error>) {
    sessionQueue.async {
      guard let continuation = self.pendingPhotoCaptureContinuation else { return }
      self.pendingPhotoCaptureContinuation = nil
      continuation.resume(with: result)
    }
  }
}
