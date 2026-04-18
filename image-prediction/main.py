import argparse
import base64
import mimetypes
import sys
from pathlib import Path

import httpx


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send an image + prompt to the local FastAPI vision endpoint."
    )
    parser.add_argument("image", type=Path, help="Path to the image file")
    parser.add_argument(
        "-p",
        "--prompt",
        default=None,
        help="Text prompt (defaults to the server's pointing-finger prompt if omitted)",
    )
    parser.add_argument(
        "-s",
        "--server",
        default="http://localhost:8000",
        help="Base URL of the FastAPI server (default: http://localhost:8000)",
    )
    args = parser.parse_args()

    if not args.image.is_file():
        print(f"Error: image not found: {args.image}", file=sys.stderr)
        return 1

    mime, _ = mimetypes.guess_type(args.image)
    if mime is None:
        mime = "image/jpeg"
    data_b64 = base64.b64encode(args.image.read_bytes()).decode("ascii")

    content: list[dict] = []
    if args.prompt:
        content.append({"type": "input_text", "text": args.prompt})
    content.append(
        {
            "type": "input_image",
            "source": {"type": "base64", "media_type": mime, "data": data_b64},
        }
    )

    payload = {
        "model": "openclaw",
        "stream": False,
        "input": [{"type": "message", "role": "user", "content": content}],
    }

    url = args.server.rstrip("/") + "/v1/responses"
    try:
        resp = httpx.post(url, json=payload, timeout=180.0)
        resp.raise_for_status()
    except httpx.HTTPStatusError as exc:
        print(f"HTTP {exc.response.status_code}: {exc.response.text}", file=sys.stderr)
        return 1
    except httpx.HTTPError as exc:
        print(f"Request error: {exc}", file=sys.stderr)
        return 1

    data = resp.json()
    try:
        text = data["output"][0]["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        print("Unexpected response shape:", data, file=sys.stderr)
        return 1

    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
