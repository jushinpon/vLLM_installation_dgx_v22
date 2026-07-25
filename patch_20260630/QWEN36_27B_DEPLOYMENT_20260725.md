# Qwen3.6-27B-FP8 Production Deployment

Deployment date: 2026-07-25

## Runtime

- Backend: `node13`, NVIDIA GB10
- Model: `Qwen/Qwen3.6-27B-FP8`
- Local path: `/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8`
- Served name: `qwen3.6-27b-fp8`
- vLLM: `0.22.1.dev0+g0b3ba88f1.d20260602`
- Context: 262,144 tokens
- Thinking: enabled by default
- Multimodal: enabled, up to four images per prompt
- Maximum concurrent sequences: 4
- KV cache capacity reported by vLLM: 1,098,544 tokens

The first cold start took approximately seven minutes, including 236 seconds
for loading 66 checkpoint shards and the first `torch.compile`/CUDA graph
warm-up. Later starts can reuse the compile cache.

## Validation

| Test | Result |
| --- | --- |
| `/health` and `/v1/models` | Passed; model ID and 262,144 context verified |
| Default thinking | Passed; reasoning output returned |
| Thinking-disabled text request | Passed; exact `TEXT_OK` response |
| Tool calling | Passed; `get_weather` call with valid JSON arguments |
| Vision request | Passed with a real JPEG |
| Long context | Passed with 130,019 prompt tokens in 256.61 seconds |
| Student gateway | Passed; authenticated model listing and generation |
| 10-student concurrent gateway load | 10/10 succeeded; no timeout or HTTP error |
| Watchdog | Passed during 10-student load; probe waited 30.20 seconds and returned `OK` |
| Fatal log scan | No OOM, traceback, engine initialization failure, or fatal error |

## Performance

The decode benchmark used a short identical prompt, thinking disabled,
temperature zero, and exactly 512 generated tokens per request. Reported rates
include request overhead and short-prompt prefill.

| Model | Single request | Four concurrent requests |
| --- | ---: | ---: |
| Qwen3.6-27B-FP8 | 8.06 tokens/s | 31.58 aggregate tokens/s |
| Previous Qwen3.6-35B-A3B-FP8 | 53.80 tokens/s | 185.45 aggregate tokens/s |

The 27B model is dense, while the previous 35B-A3B model is MoE and activates
only part of its parameters for each token. The dense model therefore has much
lower token throughput on GB10 despite its smaller total parameter count.

The 10-student gateway test generated 1,280 tokens in 48.20 seconds:

- 10 successful requests, 0 failures
- 26.56 aggregate tokens/s
- Fastest request: 16.19 seconds
- Slowest request: 48.19 seconds

Requests beyond the four active backend sequences queue normally.

## Watchdog

The watchdog runs every two minutes and restarts the backend after three
consecutive generation failures. Its generation timeout is 240 seconds so
legitimate queued requests from ten students do not cause false restarts.
Backend connection and health failures still fail quickly.

## Rollback

The previous model weights remain installed. To roll back:

```bash
cd /home/vLLM_installation_dgx_v22
perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
  --served-model-name=qwen3.6-35b-a3b-fp8 \
  --max-model-len=262144 \
  --max-num-batched-tokens=16384 \
  --max-num-seqs=4 \
  --default-chat-template-kwargs='{"enable_thinking": true}' \
  --no-language-model-only \
  --limit-mm-per-prompt='{"image":4}'
```

After a rollback, also update the manager defaults, regenerate the gateway
configuration, reinstall the watchdog, and reload nginx.
