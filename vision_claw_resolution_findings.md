# VisionClaw — Image Resolution & Photo Mode for Fine-Text Reading

Notes on how image resolution flows through the VisionClaw stack, what each AI provider does with it, and how to architect for fine-text reading (menus, signs, screens, small print) on the Ray-Ban Meta glasses.

## Hardware constraint: Bluetooth caps the live stream

The Ray-Ban Meta glasses have a **12 MP camera (3024 × 4032)**, but live video to the iOS app goes over **Bluetooth Classic**, which imposes hard limits:

- **720p maximum** (720 × 1280)
- Adaptive per-frame compression — quality drops further when BT bandwidth dips
- Frame rate options via `StreamSessionConfig`: 2, 7, 15, 24, or 30 fps
- VisionClaw default: `StreamingResolution.low` (360 × 640), 24 fps capture, throttled to 1 fps for AI

**Implication:** 720p heavily JPEG-compressed over BT is marginal for fine text. This is a transport limit, not an SDK or API problem — no provider choice fixes it.

## The fix: photos, not stream frames

The DAT SDK exposes `streamSession.capturePhoto(format: .jpeg)` — a separate code path that uses the **full 12 MP sensor** instead of the BT video stream. VisionClaw already wires this up at `StreamSessionViewModel.swift:322` (with `photoDataPublisher` and `PhotoPreviewView`), but currently only as a manual button.

### Architectural pattern for text reading

1. Stream low-res frames continuously for ambient awareness ("what am I looking at")
2. When text reading is needed, the AI model calls a new **`capturePhoto`** tool
3. The captured 12 MP JPEG is injected as a high-detail image input
4. Model reads the text from the full-resolution capture

This puts the resolution-vs-cost decision in the model's hands. Add `capturePhoto` to `ToolDeclarations` next to `execute`.

Optional refinement: a second tool `zoomedReadOfRegion(description: string)` where the model first locates the text region in a low-detail pass, then you crop client-side and re-send just that region at high detail. Cheaper and often more accurate.

## Provider comparison: tokens & internal handling

Assume input = a 3024 × 4032 JPEG from `capturePhoto`.

| Provider | Mode | What model sees | Tokens | Text-reading quality |
|---|---|---|---|---|
| Gemini Live | `mediaResolution: low` | downsampled, ~768² | 66 | poor for fine text |
| Gemini Live | `mediaResolution: medium` (default) | ~768² | 258 | OK, struggles on small print |
| Gemini Live | `mediaResolution: high` | higher internal res | higher | best Gemini option for text |
| Gemini (static, non-Live) | `media_resolution_high` | full processing | 1,120 | strong |
| OpenAI Realtime | `detail: "low"` | forced 512² | 85 | poor for fine text |
| OpenAI Realtime | `detail: "high"` | scaled to 2048² fit, then shortest side 768, **tiled** in 512² blocks | ~765 (4 tiles + 85 base) | strongest, tiles preserve detail |

### Architectural difference that matters for text

- **OpenAI tiles** the high-detail image: each 512 px region keeps full resolution. Good for documents/menus/signs where text is concentrated in regions.
- **Gemini downsamples** to one fixed internal size. Spatial info is averaged away.

## OCR/text-reading quality (public benchmarks)

- **GPT-4o**: strongest published OCR results among major models. Reasons over layout (heading→paragraph, label→field). Explicitly handles "read the serial number / read the text" prompts well.
- **Gemini 2.5 / 3**: competitive but still trails GPT-4o on dense fine-text in head-to-head comparisons.
- Both struggle with: non-Latin scripts (especially handwritten/cursive), medical imaging, very small text below ~8pt at typical phone-photo distance.

## Recommendations

### For fine text — OpenAI Realtime + on-demand photo

1. **Glasses streaming**: `StreamingResolution.medium` (504 × 896) at **2 fps** for ambient context. Lower fps → less BT compression per frame.
2. **Add a `capturePhoto` tool** the model can call.
3. **Inject the 12 MP photo as `input_image` with `detail: "high"`** — ~765 tokens per read, but you get tiled detail.
4. **Transport: WebRTC** for the audio/video session. Send captured photos via a separate HTTPS upload + reference URL to avoid bloating the WebRTC data channel.

### If staying with Gemini

- Use `mediaResolution: high`.
- Same on-demand-photo pattern.
- Lose the tiling advantage; gain Gemini's larger context window if you want to keep many photos in scope.

## Code touchpoints to change

- `samples/CameraAccess/CameraAccess/OpenClaw/ToolCallModels.swift` — add `capturePhoto` declaration
- `samples/CameraAccess/CameraAccess/OpenClaw/ToolCallRouter.swift` — route `capturePhoto` to the streaming view model rather than OpenClaw
- `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift:322` — already calls `streamSession.capturePhoto(format: .jpeg)`; expose this as a callable + return path that surfaces the JPEG bytes
- `samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift` (or replacement) — add a path to inject an image as an input message in response to a tool call, then prompt the model to continue
- `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift` — extend the system prompt to teach the model when to call `capturePhoto` vs. relying on the live stream

## Sources

- Ray-Ban Meta — Wikipedia: https://en.wikipedia.org/wiki/Ray-Ban_Meta
- Ray-Ban Meta AI Glasses specs: https://www.ray-ban.com/usa/discover-ray-ban-meta-ai-glasses/clp
- DAT SDK iOS integration: https://wearables.developer.meta.com/docs/build-integration-ios/
- StreamSessionConfig reference: https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.3/mwdatcamera_streamsessionconfig
- OpenAI Images & Vision: https://platform.openai.com/docs/guides/images-vision
- Gemini Media Resolution: https://ai.google.dev/gemini-api/docs/media-resolution
- GPT-4o Vision Guide (GetStream): https://getstream.io/blog/gpt-4o-vision-guide/
