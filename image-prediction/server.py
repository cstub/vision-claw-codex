import asyncio
import base64
import json
import logging
import os
import tempfile
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("image_api")

PROVIDER = os.getenv("PROVIDER", "openai").lower()

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o")
REASONING_EFFORT = os.getenv("REASONING_EFFORT") or None

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-pro")
_gemini_budget_raw = os.getenv("GEMINI_THINKING_BUDGET")
GEMINI_THINKING_BUDGET: int | None = int(_gemini_budget_raw) if _gemini_budget_raw else None
GEMINI_MEDIA_RESOLUTION = (os.getenv("GEMINI_MEDIA_RESOLUTION") or "").strip().lower() or None

FINGER_DETECTOR_ENABLED = os.getenv("FINGER_DETECTOR_ENABLED", "false").lower() in ("1", "true", "yes")
FINGER_DETECTOR_PATH = os.getenv(
    "FINGER_DETECTOR_PATH",
    "/Users/christoph/Development/Projects/codex-hack/finger-word-detector",
)
FINGER_DETECTOR_TOP_N = int(os.getenv("FINGER_DETECTOR_TOP_N", "5"))
FINGER_DETECTOR_TIMEOUT = float(os.getenv("FINGER_DETECTOR_TIMEOUT", "60"))

DEFAULT_PROMPT = (
    "What's the word in this image that is directly above (north) of the "
    "index finger?"
)

SYSTEM_PROMPT = (
    "You analyze images that may show a hand pointing at something with an "
    "index finger. When a pointing gesture is present, the subject of the "
    "user's question is always located directly ABOVE (north of) the tip of "
    "the index finger in 2D image coordinates — never on, below, left of, or "
    "right of the finger. Apply this constraint whenever the user refers to "
    "'this', 'that', 'this word', 'read this', or uses any similar deictic "
    "reference, and whenever a pointing hand is visible in the image."
)

openai_client = None
gemini_client = None
gemini_types = None

if PROVIDER == "openai":
    from openai import OpenAI

    if not OPENAI_API_KEY:
        raise RuntimeError("OPENAI_API_KEY not set (check your .env file).")
    openai_client = OpenAI(api_key=OPENAI_API_KEY)
    ACTIVE_MODEL = OPENAI_MODEL
elif PROVIDER == "gemini":
    from google import genai
    from google.genai import types as gemini_types

    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY not set (check your .env file).")
    gemini_client = genai.Client(api_key=GEMINI_API_KEY)
    ACTIVE_MODEL = GEMINI_MODEL
else:
    raise RuntimeError(f"Unknown PROVIDER '{PROVIDER}' (expected 'openai' or 'gemini').")

logger.info(
    "Provider=%s model=%s finger_detector=%s",
    PROVIDER,
    ACTIVE_MODEL,
    "on" if FINGER_DETECTOR_ENABLED else "off",
)

app = FastAPI()


@app.get("/v1/chat/completions")
async def health_check():
    return {
        "status": "ok",
        "provider": PROVIDER,
        "model": ACTIVE_MODEL,
        "finger_detector": FINGER_DETECTOR_ENABLED,
    }


async def detect_finger_words(image_bytes: bytes, mime: str) -> list[str] | None:
    """Run the external finger-word-detector CLI. Returns candidate list or None."""
    if not FINGER_DETECTOR_ENABLED:
        return None

    ext = ".jpg"
    if mime == "image/png":
        ext = ".png"
    elif mime == "image/webp":
        ext = ".webp"

    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
        tmp.write(image_bytes)
        tmp_path = Path(tmp.name)
    json_path = tmp_path.with_suffix(".json")

    try:
        proc = await asyncio.create_subprocess_exec(
            "uv",
            "run",
            "detect-word",
            str(tmp_path),
            "--json",
            "--top-n",
            str(FINGER_DETECTOR_TOP_N),
            cwd=FINGER_DETECTOR_PATH,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=FINGER_DETECTOR_TIMEOUT
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            logger.warning("finger-detector timed out after %ss", FINGER_DETECTOR_TIMEOUT)
            return None

        if proc.returncode != 0:
            logger.warning(
                "finger-detector exit=%d stderr=%s",
                proc.returncode,
                stderr.decode(errors="replace")[:400],
            )
            return None

        if not json_path.is_file():
            logger.info("finger-detector produced no JSON (no hand or OCR miss)")
            return None

        try:
            candidates = json.loads(json_path.read_text())
        except json.JSONDecodeError as exc:
            logger.warning("finger-detector JSON decode failed: %s", exc)
            return None

        if not isinstance(candidates, list):
            return None
        return [str(c) for c in candidates if c]
    except FileNotFoundError:
        logger.warning("`uv` binary not found on PATH; disable FINGER_DETECTOR_ENABLED or install uv")
        return None
    finally:
        tmp_path.unlink(missing_ok=True)
        json_path.unlink(missing_ok=True)


def augment_prompt_with_candidates(base_prompt: str, candidates: list[str]) -> str:
    if not candidates:
        return base_prompt
    listing = "\n".join(f"  {i + 1}. \"{c}\"" for i, c in enumerate(candidates))
    return (
        f"{base_prompt}\n\n"
        f"--- Additional signal (external geometric detector) ---\n"
        f"A separate MediaPipe + OCR pipeline analyzed this image. Its top "
        f"guesses for the word directly above the index fingertip, best first:\n"
        f"{listing}\n\n"
        f"Use this ONLY if the image actually shows a hand pointing with its "
        f"index finger. If no pointing gesture is visible, ignore this list "
        f"entirely. If a pointing gesture IS visible, treat entry 1 as a strong "
        f"prior but override it when the image clearly shows a different word."
    )


def call_openai(prompt: str, image_data_url: str) -> str:
    kwargs = {
        "model": OPENAI_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": image_data_url, "detail": "high"},
                    },
                ],
            },
        ],
    }
    if REASONING_EFFORT:
        kwargs["reasoning_effort"] = REASONING_EFFORT

    completion = openai_client.chat.completions.create(**kwargs)
    return completion.choices[0].message.content or ""


_MEDIA_RESOLUTION_MAP = {
    "low": "MEDIA_RESOLUTION_LOW",
    "medium": "MEDIA_RESOLUTION_MEDIUM",
    "high": "MEDIA_RESOLUTION_HIGH",
}


def call_gemini(prompt: str, image_bytes: bytes, mime: str) -> str:
    config_kwargs: dict = {"system_instruction": SYSTEM_PROMPT}
    if GEMINI_THINKING_BUDGET is not None:
        config_kwargs["thinking_config"] = gemini_types.ThinkingConfig(
            thinking_budget=GEMINI_THINKING_BUDGET
        )
    if GEMINI_MEDIA_RESOLUTION:
        enum_name = _MEDIA_RESOLUTION_MAP.get(GEMINI_MEDIA_RESOLUTION)
        if enum_name is None:
            raise RuntimeError(
                f"Invalid GEMINI_MEDIA_RESOLUTION={GEMINI_MEDIA_RESOLUTION!r} "
                f"(expected one of: low, medium, high)"
            )
        config_kwargs["media_resolution"] = getattr(gemini_types.MediaResolution, enum_name)

    response = gemini_client.models.generate_content(
        model=GEMINI_MODEL,
        contents=[
            gemini_types.Part.from_bytes(data=image_bytes, mime_type=mime),
            prompt,
        ],
        config=gemini_types.GenerateContentConfig(**config_kwargs),
    )
    return response.text or ""


@app.post("/v1/responses")
async def responses(body: dict, request: Request):
    client_ip = request.client.host if request.client else "unknown"
    logger.info("POST /v1/responses from %s", client_ip)

    try:
        content = body["input"][0]["content"]
    except (KeyError, IndexError, TypeError):
        logger.warning("Bad request: missing input[0].content")
        raise HTTPException(status_code=400, detail="Missing input[0].content")

    prompt_text = ""
    image_b64: str | None = None
    image_bytes: bytes | None = None
    image_media_type = "image/jpeg"
    prompt_was_default = False

    for item in content:
        item_type = item.get("type")
        if item_type == "input_text":
            prompt_text = item.get("text", "") or ""
        elif item_type == "input_image":
            source = item.get("source") or {}
            data = source.get("data")
            image_media_type = source.get("media_type", "image/jpeg")
            if data:
                image_b64 = data
                image_bytes = base64.b64decode(data)

    if image_b64 is None or image_bytes is None:
        logger.warning("Bad request: missing input_image")
        raise HTTPException(status_code=400, detail="Missing input_image in content")

    if not prompt_text.strip():
        prompt_text = DEFAULT_PROMPT
        prompt_was_default = True
    else:
        prompt_text = prompt_text.strip()

    candidates = await detect_finger_words(image_bytes, image_media_type)
    if candidates:
        logger.info("finger-detector candidates: %s", candidates)
    final_prompt = augment_prompt_with_candidates(prompt_text, candidates or [])

    if PROVIDER == "openai":
        reasoning_info = REASONING_EFFORT or "-"
        resolution_info = "high"
    else:
        reasoning_info = (
            f"thinking_budget={GEMINI_THINKING_BUDGET}"
            if GEMINI_THINKING_BUDGET is not None
            else "-"
        )
        resolution_info = GEMINI_MEDIA_RESOLUTION or "default"
    logger.info(
        "provider=%s model=%s reasoning=%s media_resolution=%s image=%s (%d bytes) prompt_default=%s candidates=%d",
        PROVIDER,
        ACTIVE_MODEL,
        reasoning_info,
        resolution_info,
        image_media_type,
        len(image_bytes),
        prompt_was_default,
        len(candidates or []),
    )
    logger.info("LLM system prompt:\n%s", SYSTEM_PROMPT)
    logger.info("LLM user prompt:\n%s", final_prompt)

    try:
        if PROVIDER == "openai":
            image_data_url = f"data:{image_media_type};base64,{image_b64}"
            text = call_openai(final_prompt, image_data_url)
        else:
            text = call_gemini(final_prompt, image_bytes, image_media_type)
    except Exception as exc:
        logger.exception("%s call failed", PROVIDER)
        raise HTTPException(status_code=502, detail=f"{PROVIDER} error: {exc}") from exc

    logger.info("response: %s", text)

    return {
        "output": [
            {"content": [{"type": "output_text", "text": text}]}
        ]
    }
