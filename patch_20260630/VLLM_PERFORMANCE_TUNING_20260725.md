# Qwen3.6-27B-FP8 performance tuning on node13

Date: 2026-07-25

## Production profile

```text
model=/local_opt/vllm-models/Qwen-Qwen3.6-27B-FP8
served_model_name=qwen3.6-27b-fp8
gpu_memory_utilization=0.85
max_model_len=131072
max_num_batched_tokens=16384
max_num_seqs=10
language_model_only=true
speculative_method=qwen3_next_mtp
num_speculative_tokens=3
performance_mode=throughput
optimization_level=2
default_chat_template_kwargs={"enable_thinking": true}
```

Hermes sends `enable_thinking=false` per request for interactive speed.
Image input is disabled in this profile.

## Benchmark method

- Requests used the public nginx gateway on port 9000.
- Each result is calculated from API-reported completion tokens divided by
  wall-clock request time.
- Thinking was disabled, `ignore_eos=true`, and each request generated a fixed
  number of output tokens.
- The benchmark script is `scripts/benchmark_qwen27_concurrency.py`.

## Candidate comparison

All comparison runs generated 256 output tokens per request.

| Profile | 1 user | 4-user aggregate | 10-user aggregate |
|---------|-------:|-----------------:|------------------:|
| 262K, multimodal, no MTP, balanced | 7.99 | 31.35 | 26.32 |
| 262K, multimodal, MTP=2, balanced | 18.54 | 59.25 | 55.94 |
| 262K, multimodal, MTP=2, throughput | 17.12 | 61.35 | 57.31 |
| 131K, text-only, MTP=2, throughput, seq=8 | 18.44 | 61.83 | 81.60 |
| 131K, text-only, MTP=2, throughput, seq=10, O2 | 18.47 | 61.51 | 140.87 |
| 131K, text-only, MTP=2, throughput, seq=10, O3 | 17.11 | 66.01 | 139.98 |
| **131K, text-only, MTP=3, throughput, seq=10, O2** | **21.58** | **60.90** | **153.80** |

Rates are output tokens per second. The final profile improves 10-user
aggregate throughput by about 5.8 times over the original 262K multimodal
profile.

## Stability result

Three consecutive 10-user tests generated 512 output tokens per request:

| Run | Aggregate tok/s |
|----:|----------------:|
| 1 | 171.18 |
| 2 | 173.59 |
| 3 | 169.91 |

Across the final candidate tests, 50 requests completed with zero errors and
zero aborts. MTP accepted 14,142 of 15,660 draft tokens (90.3%).

The engine reported 965,099 KV-cache tokens, equivalent to about 7.36
simultaneous requests only when every request consumes the full 131,072-token
context. Ten normal-length Hermes sessions can run concurrently, but ten full
131K contexts cannot.

## Watchdog behavior

The watchdog runs every two minutes and performs a real text-generation probe.
It restarts the backend after three consecutive failures, with a 15-minute
restart cooldown. Its generated restart command uses the production profile
above.

The backend deploy script takes an exclusive service lock for start, stop, and
restart operations. This prevents a manual manager command and the watchdog
from starting competing vLLM processes.
