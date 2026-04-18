/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import Photos
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

enum PhotoAnalysisWorkflowError: LocalizedError {
  case bridgeUnavailable
  case captureInProgress
  case requiresActiveStream
  case captureUnavailable
  case cancelled

  var errorDescription: String? {
    switch self {
    case .bridgeUnavailable:
      return "Photo analysis is unavailable right now."
    case .captureInProgress:
      return "A photo analysis is already in progress."
    case .requiresActiveStream:
      return "Photo analysis requires an active stream."
    case .captureUnavailable:
      return "Photo capture is unavailable right now."
    case .cancelled:
      return "Photo analysis was cancelled."
    }
  }
}

enum PhotoLibrarySaveError: LocalizedError {
  case accessDenied
  case saveFailed

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      return "Photo Library access was denied."
    case .saveFailed:
      return "The photo could not be saved to Photos."
    }
  }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var photoAnalysisText: String?
  @Published var isAnalyzingPhoto: Bool = false
  @Published var photoAnalysisError: String?
  @Published var photoAnalysisNote: String?
  @Published private(set) var isPhotoCaptureBusy: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?
  var openClawBridge: OpenClawBridge?

  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?
  private var pendingPhotoCaptureContinuation: CheckedContinuation<Data, Error>?
  private var photoAnalysisTask: Task<Void, Never>?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  private static let defaultPhotoAnalysisPrompt = "How do you pronounce this?"

  init(
    wearables: WearablesInterface,
    openClawBridge: OpenClawBridge? = nil
  ) {
    self.wearables = wearables
    self.openClawBridge = openClawBridge
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    setupVideoDecoder()
    attachListeners()
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners() {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.pendingPhotoCaptureContinuation != nil {
          self.resumePendingPhotoCapture(with: photoData.data)
          return
        }

        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    cancelPhotoAnalysisWorkflow()
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await streamSession.stop()
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    guard !isPhotoCaptureBusy else { return }
    streamSession.capturePhoto(format: .jpeg)
  }

  func analyzePhotoWithOpenClaw(
    prompt: String? = nil
  ) async -> Result<String, Error> {
    let prompt = prompt ?? StreamSessionViewModel.defaultPhotoAnalysisPrompt

    guard !isPhotoCaptureBusy else {
      return .failure(PhotoAnalysisWorkflowError.captureInProgress)
    }
    guard isStreaming else {
      return .failure(PhotoAnalysisWorkflowError.requiresActiveStream)
    }
    guard let openClawBridge else {
      return .failure(PhotoAnalysisWorkflowError.bridgeUnavailable)
    }

    isPhotoCaptureBusy = true
    defer { isPhotoCaptureBusy = false }

    do {
      let jpegData: Data
      switch streamingMode {
      case .glasses:
        jpegData = try await captureNextPhotoJPEG()
      case .iPhone:
        guard let iPhoneCameraManager else {
          return .failure(PhotoAnalysisWorkflowError.captureUnavailable)
        }
        jpegData = try await iPhoneCameraManager.capturePhoto()
      }

      photoAnalysisNote = await persistAnalyzedPhotoToLibrary(jpegData)
      return await openClawBridge.analyzeImage(jpegData: jpegData, prompt: prompt)
    } catch {
      return .failure(error)
    }
  }

  func capturePhotoForAnalysis() {
    guard !isPhotoCaptureBusy else { return }

    isAnalyzingPhoto = true
    photoAnalysisText = nil
    photoAnalysisError = nil
    photoAnalysisNote = nil

    photoAnalysisTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.photoAnalysisTask = nil }

      let result = await self.analyzePhotoWithOpenClaw()
      guard !Task.isCancelled else { return }

      switch result {
      case .success(let text):
        self.photoAnalysisText = text
      case .failure(let error):
        self.photoAnalysisError = self.photoAnalysisMessage(from: error)
      }

      self.isAnalyzingPhoto = false
    }
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  func dismissPhotoAnalysis() {
    photoAnalysisText = nil
    photoAnalysisError = nil
    photoAnalysisNote = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func captureNextPhotoJPEG() async throws -> Data {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Data, Error>) in
          guard let self else {
            continuation.resume(throwing: PhotoAnalysisWorkflowError.cancelled)
            return
          }
          guard self.pendingPhotoCaptureContinuation == nil else {
            continuation.resume(throwing: PhotoAnalysisWorkflowError.captureInProgress)
            return
          }

          self.pendingPhotoCaptureContinuation = continuation
          self.streamSession.capturePhoto(format: .jpeg)
        }
      },
      onCancel: { [weak self] in
        Task { @MainActor [weak self] in
          self?.cancelPendingPhotoCapture(with: PhotoAnalysisWorkflowError.cancelled)
        }
      }
    )
  }

  private func resumePendingPhotoCapture(with data: Data) {
    guard let continuation = pendingPhotoCaptureContinuation else { return }
    pendingPhotoCaptureContinuation = nil
    continuation.resume(returning: data)
  }

  private func cancelPendingPhotoCapture(with error: Error) {
    guard let continuation = pendingPhotoCaptureContinuation else { return }
    pendingPhotoCaptureContinuation = nil
    continuation.resume(throwing: error)
  }

  private func cancelPhotoAnalysisWorkflow() {
    photoAnalysisTask?.cancel()
    photoAnalysisTask = nil
    cancelPendingPhotoCapture(with: PhotoAnalysisWorkflowError.cancelled)
    isPhotoCaptureBusy = false
    isAnalyzingPhoto = false
    photoAnalysisText = nil
    photoAnalysisError = nil
    photoAnalysisNote = nil
  }

  private func photoAnalysisMessage(from error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  private func persistAnalyzedPhotoToLibrary(_ jpegData: Data) async -> String {
    do {
      try await savePhotoToLibrary(jpegData)
      return "Saved to Photos."
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      NSLog("[Photo] Failed to save analyzed photo: %@", message)
      return "Not saved to Photos: \(message)"
    }
  }

  private func savePhotoToLibrary(_ jpegData: Data) async throws {
    let status = await requestPhotoLibraryAuthorization()
    switch status {
    case .authorized, .limited:
      break
    default:
      throw PhotoLibrarySaveError.accessDenied
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges {
        let creationRequest = PHAssetCreationRequest.forAsset()
        creationRequest.addResource(with: .photo, data: jpegData, options: nil)
      } completionHandler: { success, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard success else {
          continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
          return
        }
        continuation.resume()
      }
    }
  }

  private func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
    let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard currentStatus == .notDetermined else { return currentStatus }

    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
