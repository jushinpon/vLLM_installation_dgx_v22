# Qwen3.8-27B-NVFP4 + DFlash 2 on Node13 (DGX Spark GB10)

## Configuration

| Item | Value |
|---|---|
| Hardware | NVIDIA DGX Spark / GB10 (128 GB unified memory) |
| vLLM version | 0.27.2.dev0 + DFlash 2 patch (PR #52816) |
| Target model | nvidia/Qwen3.8-27B-NVFP4 |
| Draft model | incoai/Qwen3.8-27B-DFlash2 |
| Quantization | ModelOpt mixed: NVFP4 (MLP) + FP8 (attention) |
| Served model name | mel_llm |
| Port | 8000 (internal) / 9000 (external via 140.117.59.195) |
| Hermes config | No changes needed |

## Detected Backends

| Component | Backend |
|---|---|
| NVFP4 GEMM | CutlassNvFp4LinearKernel (native Blackwell FP4) |
| Attention | FlashAttention |
| KV cache | FP8 |
| Speculative | DFlash 2, k=7, probabilistic sampling |

## Benchmark Results

| Test | Tokens | Time | Speed |
|---|---|---|---|
| Long generation (1024 tokens) | 1024 | 14.6s | **70.1 tok/s** |
| Short run 1 | 152 | 5.7s | 26.4 tok/s |
| Short run 2 | 132 | 4.1s | 32.0 tok/s |
| Short run 3 | 159 | 5.6s | 28.5 tok/s |

### Comparison

| Config | Speed | vs Baseline |
|---|---|---|
| No speculative | 11.5 tok/s | — |
| MTP k=3 | 30.6 tok/s | +166% |
| **DFlash 2 k=7** | **70.1 tok/s** | **+510%** |

## Startup

```bash
# Deploy with DFlash 2
bash /home/vLLM_installation_dgx_v22/deploy_qwen38_27b_dflash2.sh --deploy

# Or use the manager directly
perl /home/vLLM_installation_dgx_v22/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --model-id=/local_opt/vllm-models/nvidia-Qwen3.8-27B-NVFP4 \
  --served-model-name=mel_llm \
  --speculative-method=dflash \
  --speculative-model=/local_opt/vllm-models/incoai-Qwen3.8-27B-DFlash2 \
  --num-speculative-tokens=7 \
  --draft-sample-method=probabilistic \
  --gpu-memory-utilization=0.85 \
  --max-model-len=65536
```

## Rollback to MTP

```bash
perl /home/vLLM_installation_dgx_v22/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl backend-restart \
  --backend-host=node13 \
  --model-id=/local_opt/vllm-models/nvidia-Qwen3.8-27B-NVFP4 \
  --served-model-name=mel_llm \
  --speculative-method=mtp \
  --num-speculative-tokens=3 \
  --gpu-memory-utilization=0.85 \
  --max-model-len=65536
```

## Files Modified

| File | Change |
|---|---|
| deploy_vllm4dgx_v022_qwen35b.pl | Added dflash/dspark methods, speculative_model, draft_sample_method |
| manage_lab_vllm_nginx_from_master_v022_qwen35b.pl | Added speculative_model/draft_sample_method passthrough |
| deploy_qwen38_27b_dflash2.sh | New deployment script |
| vllm_qwen35b_watchdog.sh | Updated to DFlash 2 config |
| vLLM source (node13) | DFlash 2 patch + lm_head guard removal |
