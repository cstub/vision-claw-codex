# VisionClaw — Homework Use Case (Fine Text on Paper)

Refines the general resolution findings (`vision_claw_resolution_findings.md`) for the specific use case: kid wearing Ray-Ban Meta glasses, doing homework, asking questions about text on a worksheet or textbook page.

## Why low-res buffered frames won't work for homework

**Geometry:**
- Ray-Ban Meta camera: ~100° horizontal FOV
- Typical 12pt printed letter: ~4mm tall
- Reading distance: ~40cm from page
- At 40cm, horizontal FOV covers ~95cm of page

**Pixels per letter at each stream resolution:**

| Stream resolution | Pixels/cm | Px per 4mm letter | OCR-readable? |
|---|---|---|---|
| 360 × 640 (`StreamingResolution.low`) | 3.8 | ~1.5 | no |
| 504 × 896 (`StreamingResolution.medium`) | 5.3 | ~2.1 | no |
| 720 × 1280 (`StreamingResolution.high`) | 7.6 | ~3.0 | no |
| **`capturePhoto` 4032 × 3024 (12 MP)** | **42** | **~17** | **yes** |

OCR rule of thumb: ~16 pixels per character height for reliable reading. The video stream gives 2–3 px. The model would be guessing.

To make 720p stream readable, kid would need page within ~15cm of face — not a homework workflow.

## Implication: drop the pre-roll buffer idea for this use case

Earlier design considered a phone-side pre-roll buffer to grab the "best recent frame" at trigger time, instead of paying photo-shutter latency. That made sense for menus / signs / dynamic situations.

**For homework it doesn't help:**
- Buffer frames are still too low-res to read text (math above)
- Page is stationary — latency to fire `capturePhoto` doesn't matter
- Kid is sitting still — no "moment passes" problem

So: skip the buffer for now. Fire the shutter on intent.

## Architecture for homework mode

1. **Video stream** at 2 fps, `StreamingResolution.medium` (504 × 896). Job = **context grounding only**: "kid is looking at a worksheet, page is in frame, lighting OK."
2. **System prompt** tells the model: when the user asks anything text-related on a page in view, call `capturePhoto`. Never try to read text from the stream — it's too low-res.
3. **`capturePhoto`** returns the 12 MP JPEG. Inject as:
   - OpenAI Realtime: `input_image` with `detail: "high"` (~765 tokens, tiled)
   - Gemini Live: `mediaResolution: high`
4. **Optional `cropToRegion(boundingBox)` tool** so the model can request a tighter crop if first read is uncertain — reduces tokens on the second pass and improves accuracy.
5. **Optional client-side perspective correction** (iOS Vision framework) before upload, since pages are rarely perpendicular to the glasses.

## Homework-specific gotchas

- **Handwriting (kid's own work):** even 12 MP + GPT-4o is unreliable on messy kid handwriting. Plan for accuracy < printed text.
- **Equations with subscripts / fractions / chemistry notation:** effective font drops further. May need user pointing + crop step.
- **Lighting & glare:** glossy textbook + desk lamp = washed-out photo. Consider "low confidence → retake" loop.
- **Page tilt / perspective:** modest tilt is fine; severe angles hurt. Pre-process deskew is cheap to try.
- **Multi-problem pages:** full-worksheet 12 MP photo has plenty of pixels but model has to find "problem 3" before reading. Either ask user to point (finger occludes the very text), or OCR all and pick by problem number.

## Net summary

**For homework, the video stream is a context sensor, not a text source. Always fire the photo.**

The general "buffer + smart capture" pattern from `vision_claw_resolution_findings.md` is right for menus/signs/screens, but for stationary fine text on paper, skip the buffer and go straight to 12 MP `capturePhoto` on intent detection.
