# VisionClaw — Photo Button v1 Implementation Plan

First end-to-end image-to-OpenClaw path, on-device side. A dedicated "Photo" button that captures a 12 MP JPEG from the Ray-Ban Meta glasses and sends it to OpenClaw's Responses API with a fixed prompt. No Gemini involvement. Text-only result shown as an overlay card.

## Context / decisions already locked

- **Backend endpoint:** OpenClaw `POST /v1/responses` (verified on 2026.4.16). `/v1/chat/completions` silently drops `image_url` on this build — unusable for images.
- **Request shape (verified working):** `input_text` + `input_image` with `source: {type:"base64", media_type:"image/jpeg", data:<b64>}` under a single `{type:"message", role:"user"}` input item.
- **Prompt:** hardcoded `"What do you see in this image?"`.
- **Session continuity:** reuse existing stable session key `agent:main:glass` via `x-openclaw-session-key` header — responses share state with the rest of the agent's context. No client-side history tracking needed (Responses API stores state server-side).
- **Visible when:** button only shown while streaming, glasses mode (not iPhone camera mode).
- **Image size:** full 12 MP JPEG as-returned by the DAT SDK. No downscaling.
- **Response:** text displayed as an overlay card on top of the live video. No TTS.

## Files to change

### 1. `samples/CameraAccess/CameraAccess/OpenClaw/OpenClawBridge.swift`

Add a new method alongside `delegateTask`:

```swift
func analyzeImage(jpegData: Data, prompt: String) async -> Result<String, Error>
```

- POST `\(host):\(port)/v1/responses`.
- Headers: `Authorization: Bearer <token>`, `Content-Type: application/json`, `x-openclaw-message-channel: glass`, `x-openclaw-session-key: agent:main:glass` (reuse `stableSessionKey`).
- Body:
  ```json
  {
    "model": "openclaw",
    "stream": false,
    "input": [{
      "type": "message",
      "role": "user",
      "content": [
        {"type": "input_text",  "text": "<prompt>"},
        {"type": "input_image", "source": {
          "type": "base64",
          "media_type": "image/jpeg",
          "data": "<base64 JPEG>"
        }}
      ]
    }]
  }
  ```
- Parse: `json.output[0].content[0].text` (content items array; take first `output_text`).
- Do NOT append to `conversationHistory` — that's the chat-completions path's client-side history; Responses API tracks state on the server via the session header.
- Reuse existing `session` (`URLSession`, 120 s timeout) and `@Published lastToolCallStatus` for status surfacing — set to `.executing("analyze")` on entry, `.completed/.failed` on exit, same as `delegateTask`.

### 2. `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`

Add published state:

```swift
@Published var photoAnalysisText: String?
@Published var isAnalyzingPhoto: Bool = false
@Published var photoAnalysisError: String?
var openClawBridge: OpenClawBridge?
private var pendingPhotoAnalysis = false
```

Add methods:

```swift
func capturePhotoForAnalysis()
func dismissPhotoAnalysis()
```

`capturePhotoForAnalysis()` sets `pendingPhotoAnalysis = true`, `isAnalyzingPhoto = true`, clears `photoAnalysisText` and `photoAnalysisError`, then calls `streamSession.capturePhoto(format: .jpeg)`.

Modify the existing `photoDataPublisher` listener (`StreamSessionViewModel.swift:229-237`) to branch on the flag:

- If `pendingPhotoAnalysis` is true: reset the flag, keep `isAnalyzingPhoto` true, call `openClawBridge?.analyzeImage(jpegData: photoData.data, prompt: "What do you see in this image?")`, then set `photoAnalysisText` or `photoAnalysisError` and `isAnalyzingPhoto = false`.
- Otherwise (existing path): set `capturedPhoto` + `showPhotoPreview = true` as today.

`dismissPhotoAnalysis()` clears `photoAnalysisText` and `photoAnalysisError`.

### 3. Dependency injection

Plumb the existing `OpenClawBridge` instance into `StreamSessionViewModel.openClawBridge` at the same root composer that already wires `viewModel.geminiSessionVM`. Candidates: `CameraAccessApp.swift` or `MainAppView.swift` — find the site that instantiates both `StreamSessionViewModel` and `OpenClawBridge`, and add a single assignment.

### 4. `samples/CameraAccess/CameraAccess/Views/StreamView.swift` — ControlsView

Add a new button right after the existing glasses-mode camera button (currently `StreamView.swift:168-173`):

```swift
if viewModel.streamingMode == .glasses {
  CircleButton(icon: "text.viewfinder", text: "Photo") {
    viewModel.capturePhotoForAnalysis()
  }
  .opacity(viewModel.isAnalyzingPhoto ? 0.4 : 1.0)
  .disabled(viewModel.isAnalyzingPhoto)
}
```

Icon `text.viewfinder` distinguishes this from the existing `camera.fill` preview button and hints at OCR/analysis intent.

### 5. `samples/CameraAccess/CameraAccess/Views/StreamView.swift` — overlay card

New SwiftUI subview `PhotoAnalysisOverlay` added inside the main `ZStack`, vertically centered above the bottom controls. Shown when `viewModel.isAnalyzingPhoto || viewModel.photoAnalysisText != nil || viewModel.photoAnalysisError != nil`.

Three visual states:

- **Analyzing:** `ProgressView()` + `"Analyzing photo…"` label.
- **Result:** scrollable `Text(viewModel.photoAnalysisText ?? "")` with a close "×" button (calls `viewModel.dismissPhotoAnalysis()`).
- **Error:** same layout as result but tinted red, showing `photoAnalysisError`.

Styling: rounded rectangle, semi-transparent black background matching the existing Gemini status overlays (`Color.black.opacity(0.5)`, `cornerRadius(20)`), horizontal padding, max ~70% screen height.

### 6. Leave untouched

- Existing camera button and `PhotoPreviewView` sheet (StreamView.swift:118-127, 170-172).
- Gemini Live integration (`GeminiLiveService.swift`, `GeminiSessionViewModel.swift`).
- Existing `delegateTask` / `execute` tool routing (`OpenClawBridge.swift:70-139`, `ToolCallRouter.swift`).
- OpenClaw HTTP client for chat completions.

## Runtime sequence

1. User taps **Photo** button.
2. `StreamSessionViewModel` sets `isAnalyzingPhoto = true`, `pendingPhotoAnalysis = true`, calls `streamSession.capturePhoto(format: .jpeg)`.
3. Overlay card appears: "Analyzing photo…".
4. DAT SDK delivers JPEG via `photoDataPublisher` (~1–2 s later).
5. Listener sees flag, base64-encodes, calls `openClawBridge.analyzeImage(...)`.
6. On response: `photoAnalysisText` populated, `isAnalyzingPhoto = false`.
7. Overlay switches to the result view; user taps × to dismiss.

## Known gotchas handled

- **Shared `photoDataPublisher`:** if the user taps the existing camera button during an analysis, the flag logic ensures only the newly-captured photo routes to OpenClaw. A second tap of the Photo button is blocked by the `disabled` gate.
- **Payload size:** 12 MP JPEG ≈ 3–4 MB raw, ~5 MB base64. Fits within the existing 120 s URLSession timeout.
- **OpenClaw "fresh session" chatter:** in probes, the model appends a "Who am I?" self-introduction to every response. That's a server-side session-init issue — out of scope for this step; v1 may surface this boilerplate in the overlay. Fix is a follow-up (system prompt / paired session / permanent identity config).
- **iOS client.id mismatch (parallel bug):** `OpenClawEventClient.swift:129` sends `client.id = "ios-node"`, but OpenClaw 2026.4.16 requires `"openclaw-ios"`. Heartbeats are not actually flowing today. Independent of this plan — filed as a follow-up.

## Out of scope for v1

- Gemini-triggered photo capture (the eventual flow for the homework use cases).
- Voice answer via glasses speakers (TTS).
- Finger-pointing focus / region cropping.
- Correction-text UI for homework "wrong answer" cases.
- Structured OpenClaw response split into spoken vs. displayed text.
- Fixing the OpenClaw handshake client.id issue in `OpenClawEventClient`.
