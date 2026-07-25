#!/usr/bin/env python3
import argparse
import concurrent.futures
import json
import os
import statistics
import time
import urllib.request
import uuid
from pathlib import Path

IMAGE_DATA_URL = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAOAAAADgCAIAAACVT/22AAACbUlEQVR4nO3SMQHAIADAsDE1"
    "SEQYAnHAS49EQY+OufYHVf/rALgxKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZ"
    "lDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc"
    "2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEq"
    "aQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBm"
    "UNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkz"
    "KGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOS"
    "ZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkG"
    "Jc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDS"
    "DEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2g"
    "pBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqa"
    "QUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmU"
    "NIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkz"
    "KGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDEqaQUkzKGkGJc2gpBmUNIOS"
    "ZlDSDEqaQUkzKGkGJc2gpBmUNIOSZlDSDvNJAxQSntbiAAAAAElFTkSuQmCC"
)


def load_env_value(path: Path, name: str) -> str:
    if not path.exists():
        return ""
    prefix = name + "="
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return ""


def post_json(url: str, api_key: str, payload: dict, timeout: int) -> dict:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    elapsed = time.perf_counter() - started
    usage = body.get("usage") or {}
    completion_tokens = int(usage.get("completion_tokens") or 0)
    choice = (body.get("choices") or [{}])[0]
    return {
        "elapsed_sec": elapsed,
        "completion_tokens": completion_tokens,
        "tokens_per_sec": completion_tokens / elapsed if elapsed else 0.0,
        "finish_reason": choice.get("finish_reason"),
    }


def run_request(args, run_id: str, request_index: int) -> dict:
    prompt = (
        "Continuously output the single word TOKEN separated by one space. "
        "Do not explain, count, summarize, or stop voluntarily. "
        f"Benchmark nonce: {run_id}-{request_index}."
    )
    content = prompt
    if args.image_count:
        content = [{"type": "text", "text": prompt}]
        content.extend(
            {
                "type": "image_url",
                "image_url": {"url": args.image_data_url},
            }
            for _ in range(args.image_count)
        )
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": args.max_tokens,
        "temperature": 0,
        "ignore_eos": True,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": args.enable_thinking},
    }
    return post_json(
        args.endpoint.rstrip("/") + "/chat/completions",
        args.api_key,
        payload,
        args.timeout,
    )


def benchmark_level(args, concurrency: int) -> dict:
    run_id = uuid.uuid4().hex[:12]
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(run_request, args, run_id, index)
            for index in range(concurrency)
        ]
        results = [future.result() for future in futures]
    wall = time.perf_counter() - started
    total_tokens = sum(item["completion_tokens"] for item in results)
    latencies = [item["elapsed_sec"] for item in results]
    per_request_tps = [item["tokens_per_sec"] for item in results]
    return {
        "label": args.label,
        "concurrency": concurrency,
        "max_tokens": args.max_tokens,
        "enable_thinking": args.enable_thinking,
        "image_count": args.image_count,
        "wall_sec": round(wall, 4),
        "total_completion_tokens": total_tokens,
        "aggregate_tokens_per_sec": round(total_tokens / wall, 4),
        "mean_request_tokens_per_sec": round(statistics.mean(per_request_tps), 4),
        "median_request_latency_sec": round(statistics.median(latencies), 4),
        "max_request_latency_sec": round(max(latencies), 4),
        "finish_reasons": sorted({item["finish_reason"] for item in results}),
        "requests": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://140.117.59.195:9000/v1")
    parser.add_argument("--model", default="qwen3.6-27b-fp8")
    parser.add_argument("--label", required=True)
    parser.add_argument("--concurrency", default="1,4,10")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--enable-thinking", action="store_true")
    parser.add_argument("--image-count", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(os.environ.get("HERMES_ENV_FILE", Path.home() / ".env")),
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 0 <= args.image_count <= 4:
        raise SystemExit("--image-count must be between 0 and 4")
    args.image_data_url = IMAGE_DATA_URL if args.image_count else ""
    args.api_key = (
        os.environ.get("VLLM_API_KEY")
        or os.environ.get("OPENAI_API_KEY")
        or load_env_value(args.env_file, "VLLM_API_KEY")
        or load_env_value(args.env_file, "OPENAI_API_KEY")
    )
    if not args.api_key:
        raise SystemExit("VLLM_API_KEY or OPENAI_API_KEY is not configured")

    warmup_payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": "Reply exactly with OK."}],
        "max_tokens": 16,
        "temperature": 0,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": args.enable_thinking},
    }
    post_json(
        args.endpoint.rstrip("/") + "/chat/completions",
        args.api_key,
        warmup_payload,
        args.timeout,
    )

    rows = []
    for value in args.concurrency.split(","):
        row = benchmark_level(args, int(value))
        rows.append(row)
        print(
            f"{args.label} concurrency={row['concurrency']} "
            f"thinking={row['enable_thinking']} images={row['image_count']} "
            f"aggregate_tps={row['aggregate_tokens_per_sec']:.2f} "
            f"mean_request_tps={row['mean_request_tokens_per_sec']:.2f} "
            f"median_latency={row['median_request_latency_sec']:.2f}s"
        )

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"label": args.label, "results": rows}) + "\n")


if __name__ == "__main__":
    main()
