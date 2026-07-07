#!/usr/bin/env perl
use strict;
use FindBin;
use warnings;
use POSIX qw(strftime);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json encode_json);

# ============================================================================
# download_model_on_backend_v022_qwen35b.pl
#
# Run this script on the MASTER node.
#
# Purpose:
#   SSH into the backend vLLM node, usually node09, and download a Hugging Face
#   model snapshot into the current vLLM model directory:
#
#       /local_opt/vllm-models
#
# Current lab stack:
#   Backend node       : node09
#   vLLM install root  : /local_opt/vllm-install
#   vLLM Python        : /local_opt/vllm-install/.vllm/bin/python
#   Model root         : /local_opt/vllm-models
#   Manager script     : manage_lab_vllm_from_master_v022_qwen35b.pl
#   Backend deployer   : deploy_vllm4dgx_v022_qwen35b.pl
#   Gateway deployer   : deploy_lab_vllm_gateway_v022_qwen35b.pl
#
# Supported Qwen3.6 presets in this version:
#   qwen36_fp8
#     repo: Qwen/Qwen3.6-27B-FP8
#     served name: qwen3.6-27b-fp8
#
#   qwen36_nvfp4_text
#     repo: sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP
#     served name: qwen3.6-27b-text-nvfp4-mtp
#     recommended for text-only OpenClaw/Hermes tests on Blackwell/GB10.
#
#   qwen36_nvfp4
#     repo: sakamakismile/Qwen3.6-27B-NVFP4
#     served name: qwen3.6-27b-nvfp4
#
#   qwen36_awq
#     repo: cyankiwi/Qwen3.6-27B-AWQ-INT4
#     served name: qwen3.6-27b-awq-int4
#
# Current workflow uses:
#   manage_lab_vllm_from_master_v022_qwen35b.pl
#   --model-id=/local_opt/vllm-models/...
#
# Main actions:
#   status
#   download
#   check-path
#   inspect-config
#   print-deploy-command
#   list-local-models
#   remove-local-model
#   list-presets
# ============================================================================

my %PRESETS = (
    qwen36_fp8 => {
        repo_id                   => 'Qwen/Qwen3.6-27B-FP8',
        dest_basename             => 'Qwen-Qwen3.6-27B-FP8',
        served_model_name         => 'qwen3.6-27b-fp8',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.85',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '32768',
        disable_thinking          => 1,
        note                      => 'Official FP8. Best first choice for stability if you want Qwen3.6 on vLLM.',
    },
    qwen36_nvfp4_text => {
        repo_id                   => 'sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP',
        dest_basename             => 'sakamakismile-Qwen3.6-27B-Text-NVFP4-MTP',
        served_model_name         => 'qwen3.6-27b-text-nvfp4-mtp',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Text-only NVFP4/MTP sibling for Blackwell/GB10. Recommended NVFP4 starting point.',
    },
    qwen36_nvfp4 => {
        repo_id                   => 'sakamakismile/Qwen3.6-27B-NVFP4',
        dest_basename             => 'sakamakismile-Qwen3.6-27B-NVFP4',
        served_model_name         => 'qwen3.6-27b-nvfp4',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Original NVFP4 compressed-tensors checkpoint. Test before production.',
    },
    qwen36_awq => {
        repo_id                   => 'cyankiwi/Qwen3.6-27B-AWQ-INT4',
        dest_basename             => 'cyankiwi-Qwen3.6-27B-AWQ-INT4',
        served_model_name         => 'qwen3.6-27b-awq-int4',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.80',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'AWQ INT4. Broad compatibility, lower VRAM than FP8. Test quality/tool behavior.',
    },
    qwen35 => {
        repo_id                   => 'Qwen/Qwen3.5-35B-A3B',
        dest_basename             => 'Qwen-Qwen3.5-35B-A3B',
        served_model_name         => 'qwen3.5-35b-a3b',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3.5 35B-A3B FP8 alternative for GB10.',
    },
    gemma4 => {
        repo_id                   => 'google/gemma-4-26B-A4B-it',
        dest_basename             => 'google-gemma-4-26B-A4B-it',
        served_model_name         => 'gemma-4-26b-a4b-it',
        tool_call_parser          => 'gemma4',
        reasoning_parser          => 'gemma4',
        gpu_memory_utilization    => '0.85',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '32768',
        disable_thinking          => 1,
        note                      => 'Gemma 4 26B-A4B-it stable BF16 test preset.',
    },
    qwen36_35b_a3b_fp8 => {
        repo_id                   => 'Qwen/Qwen3.6-35B-A3B-FP8',
        dest_basename             => 'Qwen-Qwen3.6-35B-A3B-FP8',
        served_model_name         => 'qwen3.6-35b-a3b-fp8',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Recommended Qwen3.6 35B-A3B FP8 for GB10. 96GB shared memory, optimized for 70% utilization.',
    },
    nemotron_nano_30b_fp8 => {
        repo_id                   => 'nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        dest_basename             => 'nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        served_model_name         => 'nemotron-3-nano-30b-a3b-fp8',
        tool_call_parser          => 'nemotron',
        reasoning_parser          => 'nemotron',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 0,
        note                      => 'NVIDIA Nemotron-3 Nano 30B-A3B MoE FP8. ~3B active params. Good MoE comparison vs Qwen3.6-35B-A3B.',
    },
    qwen3_14b_fp8 => {
        repo_id                   => 'nvidia/Qwen3-14B-FP8',
        dest_basename             => 'nvidia-Qwen3-14B-FP8',
        served_model_name         => 'qwen3-14b-fp8',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.85',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 14B dense FP8. Fills gap between 7B and 27B. Good dense baseline.',
    },
    qwen3_32b_nvfp4 => {
        repo_id                   => 'nvidia/Qwen3-32B-NVFP4',
        dest_basename             => 'nvidia-Qwen3-32B-NVFP4',
        served_model_name         => 'qwen3-32b-nvfp4',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 32B dense NVFP4. Tests NVFP4 effectiveness on larger dense model.',
    },
    llama_8b_fp8 => {
        repo_id                   => 'nvidia/Llama-3.1-8B-Instruct-FP8',
        dest_basename             => 'nvidia-Llama-3.1-8B-Instruct-FP8',
        served_model_name         => 'llama-3.1-8b-fp8',
        tool_call_parser          => 'llama',
        reasoning_parser          => 'llama',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Llama 3.1 8B FP8 (NVidia-optimized). Industry reference model for latency/speed comparison.',
    },
    phi4_reasoning_fp8 => {
        repo_id                   => 'nvidia/Phi-4-reasoning-plus-FP8',
        dest_basename             => 'nvidia-Phi-4-reasoning-plus-FP8',
        served_model_name         => 'phi-4-reasoning-plus-fp8',
        tool_call_parser          => 'phi3',
        reasoning_parser          => 'phi3',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Microsoft Phi-4 reasoning-plus FP8. Small dense model, different architecture test.',
    },
    nemotron_nano_30b_fp8 => {
        repo_id                   => 'nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        dest_basename             => 'nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        served_model_name         => 'nemotron-3-nano-30b-a3b-fp8',
        tool_call_parser          => 'nemotron',
        reasoning_parser          => 'nemotron',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 0,
        note                      => 'NVIDIA Nemotron-3 Nano 30B-A3B MoE FP8. ~3B active params. Good MoE comparison vs Qwen3.6-35B-A3B.',
    },
    qwen3_14b_fp8 => {
        repo_id                   => 'nvidia/Qwen3-14B-FP8',
        dest_basename             => 'nvidia-Qwen3-14B-FP8',
        served_model_name         => 'qwen3-14b-fp8',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.85',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 14B dense FP8. Fills gap between 7B and 27B. Good dense baseline.',
    },
    qwen3_32b_nvfp4 => {
        repo_id                   => 'nvidia/Qwen3-32B-NVFP4',
        dest_basename             => 'nvidia-Qwen3-32B-NVFP4',
        served_model_name         => 'qwen3-32b-nvfp4',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 32B dense NVFP4. Tests NVFP4 effectiveness on larger dense model.',
    },
    llama_8b_fp8 => {
        repo_id                   => 'nvidia/Llama-3.1-8B-Instruct-FP8',
        dest_basename             => 'nvidia-Llama-3.1-8B-Instruct-FP8',
        served_model_name         => 'llama-3.1-8b-fp8',
        tool_call_parser          => 'llama',
        reasoning_parser          => 'llama',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Llama 3.1 8B FP8 (NVidia-optimized). Industry reference model for latency/speed comparison.',
    },
    phi4_reasoning_fp8 => {
        repo_id                   => 'nvidia/Phi-4-reasoning-plus-FP8',
        dest_basename             => 'nvidia-Phi-4-reasoning-plus-FP8',
        served_model_name         => 'phi-4-reasoning-plus-fp8',
        tool_call_parser          => 'phi3',
        reasoning_parser          => 'phi3',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Microsoft Phi-4 reasoning-plus FP8. Small dense model, different architecture test.',
    },
);

my %OPT = (
    action                    => shift(@ARGV) || 'help',

    # SSH/backend
    backend_host              => 'node13',
    backend_ssh_user          => 'root',
    backend_ssh_opts          => '-o BatchMode=yes -o ConnectTimeout=10',

    # Model download
    repo_id                   => '',
    dest_dir                  => '',
    revision                  => '',
    default_root              => '/local_opt/vllm-models',
    force                     => 0,

    # Hugging Face token handling
    hf_token                  => '',
    hf_token_env              => 'HF_TOKEN',
    use_local_hf_token_env    => 0,
    use_remote_hf_token_env   => 1,

    # Current vLLM installation
    backend_python            => '/local_opt/vllm-install/.vllm/bin/python',
    backend_venv              => '/local_opt/vllm-install/.vllm',
    vllm_src_root             => '/local_opt/vllm-install/vllm',

    # Current manager/deployment defaults
    manager_script            => 'manage_lab_vllm_from_master_v022_qwen35b.pl',
    setup_dir                 => ,

    backend_port              => 8000,
    gateway_port              => 9000,

    served_model_name         => '',
    public_model_name         => '',
    backend_model_name        => '',

    gpu_memory_utilization    => '',
    max_model_len             => '',
    max_num_seqs              => '',
    max_num_batched_tokens    => '',
    max_concurrent_per_student=> '4',
    rpm_limit                 => '60',
    client_timeout            => '60',
    downstream_timeout        => '600',
    request_hard_timeout      => '900',
    max_children              => '96',

    # Model-specific deployment preset:
    #   auto, qwen35, qwen36_fp8, qwen36_nvfp4_text, qwen36_nvfp4,
    #   qwen36_awq, gemma4, generic
    preset                    => 'auto',

    tool_call_parser          => '',
    reasoning_parser          => '',
    disable_thinking          => 1,

    # Optional extra flags to print in the deploy command through manager.
    # This assumes your manage script accepts --backend-extra-args.
    backend_extra_args        => '',

    # Python snapshot_download behavior
    resume_download           => 1,
    local_dir_use_symlinks    => 0,

    # Misc
    dry_run                   => 0,
    nemotron_nano_30b_fp8 => {
        repo_id                   => 'nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        dest_basename             => 'nvidia-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-FP8',
        served_model_name         => 'nemotron-3-nano-30b-a3b-fp8',
        tool_call_parser          => 'nemotron',
        reasoning_parser          => 'nemotron',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 0,
        note                      => 'NVIDIA Nemotron-3 Nano 30B-A3B MoE FP8. ~3B active params. Good MoE comparison vs Qwen3.6-35B-A3B.',
    },
    qwen3_14b_fp8 => {
        repo_id                   => 'nvidia/Qwen3-14B-FP8',
        dest_basename             => 'nvidia-Qwen3-14B-FP8',
        served_model_name         => 'qwen3-14b-fp8',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.85',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 14B dense FP8. Fills gap between 7B and 27B. Good dense baseline.',
    },
    qwen3_32b_nvfp4 => {
        repo_id                   => 'nvidia/Qwen3-32B-NVFP4',
        dest_basename             => 'nvidia-Qwen3-32B-NVFP4',
        served_model_name         => 'qwen3-32b-nvfp4',
        tool_call_parser          => 'qwen3_coder',
        reasoning_parser          => 'qwen3',
        gpu_memory_utilization    => '0.70',
        max_model_len             => '32768',
        max_num_seqs              => '8',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Qwen3 32B dense NVFP4. Tests NVFP4 effectiveness on larger dense model.',
    },
    llama_8b_fp8 => {
        repo_id                   => 'nvidia/Llama-3.1-8B-Instruct-FP8',
        dest_basename             => 'nvidia-Llama-3.1-8B-Instruct-FP8',
        served_model_name         => 'llama-3.1-8b-fp8',
        tool_call_parser          => 'llama',
        reasoning_parser          => 'llama',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Llama 3.1 8B FP8 (NVidia-optimized). Industry reference model for latency/speed comparison.',
    },
    phi4_reasoning_fp8 => {
        repo_id                   => 'nvidia/Phi-4-reasoning-plus-FP8',
        dest_basename             => 'nvidia-Phi-4-reasoning-plus-FP8',
        served_model_name         => 'phi-4-reasoning-plus-fp8',
        tool_call_parser          => 'phi3',
        reasoning_parser          => 'phi3',
        gpu_memory_utilization    => '0.90',
        max_model_len             => '32768',
        max_num_seqs              => '16',
        max_num_batched_tokens    => '8192',
        disable_thinking          => 1,
        note                      => 'Microsoft Phi-4 reasoning-plus FP8. Small dense model, different architecture test.',
    },
);

parse_args(\%OPT, \@ARGV);
apply_derived_options(\%OPT);
main();
exit 0;

# ============================================================================
# Main
# ============================================================================

sub main {
    my $a = $OPT{action};

    if ($a eq 'help') {
        usage();
    }
    elsif ($a eq 'list-presets') {
        list_presets();
    }
    elsif ($a eq 'status') {
        show_status();
    }
    elsif ($a eq 'download') {
        download_model();
    }
    elsif ($a eq 'check-path') {
        check_path();
    }
    elsif ($a eq 'inspect-config') {
        inspect_config();
    }
    elsif ($a eq 'print-deploy-command') {
        print_deploy_command();
    }
    elsif ($a eq 'list-local-models') {
        list_local_models();
    }
    elsif ($a eq 'remove-local-model') {
        remove_local_model();
    }
    else {
        die "Unknown action: $a\nUse --help for usage.\n";
    }
}

# ============================================================================
# Actions
# ============================================================================

sub list_presets {
    print "=== AVAILABLE PRESETS ===\n";
    for my $name (sort keys %PRESETS) {
        my $p = $PRESETS{$name};
        print "preset: $name\n";
        print "  repo_id            = $p->{repo_id}\n";
        print "  dest basename      = $p->{dest_basename}\n";
        print "  served model name  = $p->{served_model_name}\n";
        print "  parser             = " . ($p->{tool_call_parser} || '(none)') . "\n";
        print "  reasoning parser   = " . ($p->{reasoning_parser} || '(none)') . "\n";
        print "  gpu util           = $p->{gpu_memory_utilization}\n";
        print "  max model len      = $p->{max_model_len}\n";
        print "  max num seqs       = $p->{max_num_seqs}\n";
        print "  max batched tokens = $p->{max_num_batched_tokens}\n";
        print "  note               = $p->{note}\n";
        print "\n";
    }
}

sub show_status {
    print "=== BACKEND CONNECTION ===\n";
    print "Backend host : $OPT{backend_host}\n";
    print "SSH user     : $OPT{backend_ssh_user}\n";
    print "SSH opts     : $OPT{backend_ssh_opts}\n";
    print "\n";

    print "=== BACKEND PYTHON CHECK ===\n";
    my ($ok1, $out1) = run_ssh(shell_quote($OPT{backend_python}) . " --version 2>&1");
    print_result($ok1, $out1);

    print "\n=== BACKEND VLLM CHECK ===\n";
    my $py_vllm = <<'PY';
import json
out = {}
try:
    import vllm
    out["vllm_version"] = getattr(vllm, "__version__", None)
    out["vllm_file"] = getattr(vllm, "__file__", None)
    out["ok"] = True
except Exception as e:
    out["ok"] = False
    out["error"] = str(e)
print(json.dumps(out, indent=2))
PY
    my ($ok2, $out2) = run_remote_python($py_vllm);
    print_result($ok2, $out2);

    print "\n=== HUGGINGFACE_HUB CHECK ===\n";
    my $py_hf = <<'PY';
import json
out = {}
try:
    import huggingface_hub
    out["ok"] = True
    out["huggingface_hub_version"] = getattr(huggingface_hub, "__version__", None)
except Exception as e:
    out["ok"] = False
    out["error"] = str(e)
print(json.dumps(out, indent=2))
PY
    my ($ok3, $out3) = run_remote_python($py_hf);
    print_result($ok3, $out3);

    print "\n=== MODEL ROOT ===\n";
    my ($ok4, $out4) = run_ssh("mkdir -p " . shell_quote($OPT{default_root}) . " && ls -ld " . shell_quote($OPT{default_root}));
    print_result($ok4, $out4);

    if ($OPT{repo_id} || $OPT{dest_dir}) {
        set_default_dest_if_needed();
        print "\n=== REQUESTED MODEL PATH ===\n";
        print "Repo ID  : " . ($OPT{repo_id} || '(not set)') . "\n";
        print "Dest dir : $OPT{dest_dir}\n";
        print "Exists   : " . (remote_dir_exists($OPT{dest_dir}) ? 'yes' : 'no') . "\n";
        print "Config   : " . (remote_file_exists("$OPT{dest_dir}/config.json") ? 'yes' : 'no') . "\n";
    }
}

sub download_model {
    die "--repo-id is required; or use --preset=qwen36_fp8 / qwen36_nvfp4_text / qwen36_nvfp4 / qwen36_awq\n"
        unless $OPT{repo_id};

    set_default_dest_if_needed();
    infer_served_names_if_needed();
    apply_preset();

    print "=== DOWNLOAD REQUEST ===\n";
    print "Backend host      : $OPT{backend_host}\n";
    print "Repo ID           : $OPT{repo_id}\n";
    print "Dest dir          : $OPT{dest_dir}\n";
    print "Revision          : " . ($OPT{revision} || '(default)') . "\n";
    print "Backend Python    : $OPT{backend_python}\n";
    print "Preset            : $OPT{preset}\n";
    print "Served model name : $OPT{served_model_name}\n";
    print "Force             : " . ($OPT{force} ? 'yes' : 'no') . "\n";
    print "Dry run           : " . ($OPT{dry_run} ? 'yes' : 'no') . "\n";
    print "\n";

    my $exists = remote_dir_exists($OPT{dest_dir});
    if ($exists && !$OPT{force}) {
        print "Destination already exists on backend:\n";
        print "  $OPT{dest_dir}\n";
        print "\nUse --force to overwrite, or reuse this path.\n\n";
        inspect_config_if_possible();
        print_deploy_command();
        return;
    }

    if ($exists && $OPT{force}) {
        print "Removing existing destination because --force was used:\n";
        print "  $OPT{dest_dir}\n";
        my ($ok_rm, $out_rm) = run_ssh("rm -rf " . shell_quote($OPT{dest_dir}));
        die "Cannot remove existing destination:\n$out_rm\n" unless $ok_rm;
    }

    my $parent = parent_dir($OPT{dest_dir});
    my ($ok_mkdir, $out_mkdir) = run_ssh("mkdir -p " . shell_quote($parent));
    die "Cannot create parent dir on backend:\n$out_mkdir\n" unless $ok_mkdir;

    my $revision_py = $OPT{revision} ? py_string($OPT{revision}) : 'None';
    my $repo_py     = py_string($OPT{repo_id});
    my $dest_py     = py_string($OPT{dest_dir});
    my $resume_py   = $OPT{resume_download} ? 'True' : 'False';
    my $symlink_py  = $OPT{local_dir_use_symlinks} ? 'True' : 'False';

    my $py = <<"PY";
import os
import json
from huggingface_hub import snapshot_download

repo_id = $repo_py
local_dir = $dest_py
revision = $revision_py

token = None
if os.environ.get("HF_TOKEN"):
    token = os.environ.get("HF_TOKEN")
elif os.environ.get("HUGGING_FACE_HUB_TOKEN"):
    token = os.environ.get("HUGGING_FACE_HUB_TOKEN")

print(json.dumps({
    "repo_id": repo_id,
    "local_dir": local_dir,
    "revision": revision,
    "has_token": bool(token),
}, indent=2))

path = snapshot_download(
    repo_id=repo_id,
    local_dir=local_dir,
    revision=revision,
    token=token,
    resume_download=$resume_py,
    local_dir_use_symlinks=$symlink_py,
)

print("SNAPSHOT_DOWNLOAD_OK")
print(path)
PY

    my $env_prefix = build_remote_env_prefix();
    my $remote_cmd =
        $env_prefix
        . shell_quote($OPT{backend_python})
        . " - <<'PY'\n$py\nPY";

    my ($ok, $out) = run_ssh($remote_cmd);
    die "Download failed:\n$out\n" unless $ok;

    print "=== DOWNLOAD OUTPUT ===\n";
    print $out;
    print "\n" unless $out =~ /\n\z/;

    die "Downloaded path not found on backend: $OPT{dest_dir}\n"
        unless remote_dir_exists($OPT{dest_dir});

    die "Downloaded model path missing config.json: $OPT{dest_dir}/config.json\n"
        unless remote_file_exists("$OPT{dest_dir}/config.json");

    print "\nDOWNLOAD OK\n";
    inspect_config_if_possible();

    print "\n";
    print_deploy_command();
}

sub check_path {
    die "--dest-dir is required\n" unless $OPT{dest_dir};

    print "=== CHECK MODEL PATH ON BACKEND ===\n";
    print "Backend host : $OPT{backend_host}\n";
    print "Dest dir     : $OPT{dest_dir}\n";
    print "\n";

    my $exists = remote_dir_exists($OPT{dest_dir});
    my $config = remote_file_exists("$OPT{dest_dir}/config.json");

    print "Path exists  : " . ($exists ? 'yes' : 'no') . "\n";
    print "config.json  : " . ($config ? 'yes' : 'no') . "\n";

    die "FAIL: path does not exist on backend\n" unless $exists;
    die "FAIL: path exists but config.json is missing\n" unless $config;

    print "PASS\n";
}

sub inspect_config {
    die "--dest-dir is required\n" unless $OPT{dest_dir};
    inspect_config_if_possible();
}

sub print_deploy_command {
    set_default_dest_if_needed() if $OPT{repo_id} && !$OPT{dest_dir};
    infer_served_names_if_needed();
    apply_preset();

    die "--dest-dir is required\n" unless $OPT{dest_dir};
    die "--served-model-name is required or inferable from --repo-id/--preset\n" unless $OPT{served_model_name};

    my @cmd = (
        'perl', $OPT{manager_script}, 'apply-all',
        "--backend-host=$OPT{backend_host}",
        "--backend-port=$OPT{backend_port}",
        "--gateway-port=$OPT{gateway_port}",
        "--model-id=$OPT{dest_dir}",
        "--served-model-name=$OPT{served_model_name}",
        "--public-model-name=$OPT{public_model_name}",
        "--backend-model-name=$OPT{backend_model_name}",
        "--gpu-memory-utilization=$OPT{gpu_memory_utilization}",
        "--max-model-len=$OPT{max_model_len}",
        "--max-num-seqs=$OPT{max_num_seqs}",
        "--max-num-batched-tokens=$OPT{max_num_batched_tokens}",
        "--max-concurrent-per-student=$OPT{max_concurrent_per_student}",
        "--rpm-limit=$OPT{rpm_limit}",
        "--client-timeout=$OPT{client_timeout}",
        "--downstream-timeout=$OPT{downstream_timeout}",
        "--request-hard-timeout=$OPT{request_hard_timeout}",
        "--max-children=$OPT{max_children}",
    );

    push @cmd, "--tool-call-parser=$OPT{tool_call_parser}" if $OPT{tool_call_parser} ne '';
    push @cmd, "--reasoning-parser=$OPT{reasoning_parser}" if $OPT{reasoning_parser} ne '';
    push @cmd, '--disable-thinking' if $OPT{disable_thinking};
    push @cmd, "--backend-extra-args=$OPT{backend_extra_args}" if $OPT{backend_extra_args} ne '';

    print "=== DEPLOY COMMAND FOR CURRENT MANAGER ===\n";
    print "Run on MASTER node:\n\n";
    print "cd " . shell_quote_local($OPT{setup_dir}) . "\n\n";
    print format_shell_command(@cmd);
    print "\n";

    print "=== NOTES ===\n";
    print "Preset: $OPT{preset}\n";
    print "Model path on backend:\n";
    print "  $OPT{dest_dir}\n\n";
    print "Student/OpenClaw Base URL:\n";
    print "  http://MASTER_PUBLIC_IP:$OPT{gateway_port}/v1\n\n";
    print "Student/OpenClaw model name:\n";
    print "  $OPT{public_model_name}\n\n";

    if ($OPT{preset} =~ /nvfp4/i) {
        print "NVFP4 note:\n";
        print "  Test startup carefully. If vLLM reports missing quantization/backend flags,\n";
        print "  your deploy_vllm4dgx_v022_qwen35b.pl may need extra support for modelopt,\n";
        print "  moe-backend, or checkpoint-specific requirements.\n\n";
    }
}

sub list_local_models {
    my $cmd = "find " . shell_quote($OPT{default_root})
            . " -maxdepth 2 -name config.json -type f -printf '%h\\n' | sort";
    my ($ok, $out) = run_ssh($cmd);
    die "Failed to list local models:\n$out\n" unless $ok;

    print "=== LOCAL MODEL PATHS ON $OPT{backend_host} ===\n";
    if ($out =~ /\S/) {
        print $out;
        print "\n" unless $out =~ /\n\z/;
    } else {
        print "(none found under $OPT{default_root})\n";
    }
}

sub remove_local_model {
    die "--dest-dir is required\n" unless $OPT{dest_dir};

    die "Refusing to remove path outside default root: $OPT{dest_dir}\n"
        unless index($OPT{dest_dir}, $OPT{default_root} . '/') == 0;

    print "This will remove model directory on backend:\n";
    print "  $OPT{backend_host}:$OPT{dest_dir}\n";

    if (!$OPT{force}) {
        die "Use --force to confirm removal.\n";
    }

    my ($ok, $out) = run_ssh("rm -rf " . shell_quote($OPT{dest_dir}));
    die "Failed to remove model:\n$out\n" unless $ok;

    print "REMOVE OK\n";
}

# ============================================================================
# Helpers
# ============================================================================

sub inspect_config_if_possible {
    if (!$OPT{dest_dir}) {
        print "No --dest-dir set; cannot inspect config.\n";
        return;
    }

    if (!remote_file_exists("$OPT{dest_dir}/config.json")) {
        print "config.json not found at $OPT{dest_dir}/config.json\n";
        return;
    }

    my $py = <<'PY';
import json, os
path = os.environ["MODEL_CONFIG"]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

keys = [
    "model_type",
    "architectures",
    "num_hidden_layers",
    "hidden_size",
    "num_attention_heads",
    "num_key_value_heads",
    "max_position_embeddings",
    "torch_dtype",
    "quantization_config",
]
out = {}
for k in keys:
    if k in cfg:
        out[k] = cfg[k]
print(json.dumps(out, indent=2, ensure_ascii=False))
PY

    my $remote_cmd =
        "MODEL_CONFIG=" . shell_quote("$OPT{dest_dir}/config.json") . " "
        . shell_quote($OPT{backend_python})
        . " - <<'PY'\n$py\nPY";

    my ($ok, $out) = run_ssh($remote_cmd);
    print "=== MODEL CONFIG SUMMARY ===\n";
    print $out;
    print "\n" unless $out =~ /\n\z/;
}

sub apply_derived_options {
    my ($opt) = @_;

    apply_preset_repo_defaults();
    set_default_dest_if_needed() if $opt->{repo_id} && !$opt->{dest_dir};
    infer_served_names_if_needed();
    apply_preset();
}

sub apply_preset_repo_defaults {
    my $preset = $OPT{preset} || 'auto';
    return if $preset eq 'auto' || $preset eq 'generic';

    die "Invalid --preset=$preset. Use auto, qwen36_35b_a3b_fp8, qwen35, qwen36_fp8, qwen36_nvfp4_text, qwen36_nvfp4, qwen36_awq, gemma4, nemotron_nano_30b_fp8, qwen3_14b_fp8, qwen3_32b_nvfp4, llama_8b_fp8, phi4_reasoning_fp8, or generic.\n"
        unless exists $PRESETS{$preset};

    my $p = $PRESETS{$preset};

    $OPT{repo_id} = $p->{repo_id} if !$OPT{repo_id};
    $OPT{served_model_name} = $p->{served_model_name} if !$OPT{served_model_name};

    if (!$OPT{dest_dir}) {
        $OPT{dest_dir} = "$OPT{default_root}/$p->{dest_basename}";
    }
}

sub set_default_dest_if_needed {
    return if $OPT{dest_dir};
    die "--repo-id is required to infer --dest-dir\n" unless $OPT{repo_id};

    my $safe = $OPT{repo_id};
    $safe =~ s{/}{-}g;
    $safe =~ s/[^A-Za-z0-9._-]/_/g;

    $OPT{dest_dir} = "$OPT{default_root}/$safe";
}

sub infer_served_names_if_needed {
    my $name = $OPT{served_model_name};

    if (!$name && $OPT{repo_id}) {
        my $repo = $OPT{repo_id};

        if ($repo =~ m{Qwen/Qwen3\.6-35B-A3B-FP8}i) {
            $name = 'qwen3.6-35b-a3b-fp8';
        }
        elsif ($repo =~ m{Qwen/Qwen3\.6-27B-FP8}i) {
            $name = 'qwen3.6-27b-fp8';
        }
        elsif ($repo =~ m{Qwen3\.6-27B-Text-NVFP4-MTP}i) {
            $name = 'qwen3.6-27b-text-nvfp4-mtp';
        }
        elsif ($repo =~ m{Qwen3\.6-27B-NVFP4}i) {
            $name = 'qwen3.6-27b-nvfp4';
        }
        elsif ($repo =~ m{Qwen3\.6-27B-AWQ-INT4}i) {
            $name = 'qwen3.6-27b-awq-int4';
        }
        elsif ($repo =~ m{Qwen/Qwen3\.5-35B-A3B}i) {
            $name = 'qwen3.5-35b-a3b';
        }
        elsif ($repo =~ m{google/gemma-4-26B-A4B-it}i) {
            $name = 'gemma-4-26b-a4b-it';
        }
        else {
            $name = $repo;
            $name =~ s{^.*/}{};
            $name = lc($name);
            $name =~ s/[^a-z0-9._-]+/-/g;
        }

        $OPT{served_model_name} = $name;
    }

    $OPT{public_model_name}  = $OPT{served_model_name} if !$OPT{public_model_name};
    $OPT{backend_model_name} = $OPT{served_model_name} if !$OPT{backend_model_name};
}

sub apply_preset {
    my $preset = $OPT{preset} || 'auto';

    if ($preset eq 'auto') {
        my $id = join(' ', grep { defined && $_ ne '' } (
            $OPT{repo_id},
            $OPT{served_model_name},
            $OPT{dest_dir},
        ));

        if ($id =~ /gemma-?4/i) {
            $preset = 'gemma4';
        }
        elsif ($id =~ /qwen3\.6.*35b.*a3b.*fp8|qwen3\.6.*fp8.*35b/i) {
            $preset = 'qwen36_35b_a3b_fp8';
        }
        elsif ($id =~ /qwen3\.6.*fp8/i) {
            $preset = 'qwen36_fp8';
        }
        elsif ($id =~ /qwen3\.6.*text.*nvfp4.*mtp/i) {
            $preset = 'qwen36_nvfp4_text';
        }
        elsif ($id =~ /qwen3\.6.*nvfp4/i) {
            $preset = 'qwen36_nvfp4';
        }
        elsif ($id =~ /qwen3\.6.*awq/i) {
            $preset = 'qwen36_awq';
        }
        elsif ($id =~ /qwen3\.5|qwen35|qwen/i) {
            $preset = 'qwen35';
        }
        else {
            $preset = 'generic';
        }

        $OPT{preset} = $preset;
    }

    if (exists $PRESETS{$preset}) {
        my $p = $PRESETS{$preset};
        $OPT{tool_call_parser}       = $p->{tool_call_parser}       if $OPT{tool_call_parser} eq '' && defined $p->{tool_call_parser};
        $OPT{reasoning_parser}       = $p->{reasoning_parser}       if $OPT{reasoning_parser} eq '' && defined $p->{reasoning_parser};
        $OPT{gpu_memory_utilization} = $p->{gpu_memory_utilization} if $OPT{gpu_memory_utilization} eq '' && defined $p->{gpu_memory_utilization};
        $OPT{max_model_len}          = $p->{max_model_len}          if $OPT{max_model_len} eq '' && defined $p->{max_model_len};
        $OPT{max_num_seqs}           = $p->{max_num_seqs}           if $OPT{max_num_seqs} eq '' && defined $p->{max_num_seqs};
        $OPT{max_num_batched_tokens} = $p->{max_num_batched_tokens} if $OPT{max_num_batched_tokens} eq '' && defined $p->{max_num_batched_tokens};
        $OPT{disable_thinking}       = $p->{disable_thinking}       if defined $p->{disable_thinking};
    }
    elsif ($preset eq 'generic') {
        $OPT{gpu_memory_utilization} = '0.85'  if $OPT{gpu_memory_utilization} eq '';
        $OPT{max_model_len} = '32768'          if $OPT{max_model_len} eq '';
        $OPT{max_num_seqs} = '8'               if $OPT{max_num_seqs} eq '';
        $OPT{max_num_batched_tokens} = '32768' if $OPT{max_num_batched_tokens} eq '';
    }
    else {
        die "Invalid --preset=$preset. Use auto, qwen35, qwen36_fp8, qwen36_nvfp4_text, qwen36_nvfp4, qwen36_awq, gemma4, nemotron_nano_30b_fp8, qwen3_14b_fp8, qwen3_32b_nvfp4, llama_8b_fp8, phi4_reasoning_fp8, or generic.\n";
    }
}

sub build_remote_env_prefix {
    my @parts;

    if ($OPT{hf_token}) {
        push @parts, "HF_TOKEN=" . shell_quote($OPT{hf_token});
    }
    elsif ($OPT{use_local_hf_token_env}) {
        my $env_name = $OPT{hf_token_env} || 'HF_TOKEN';
        my $token = $ENV{$env_name} || '';
        die "Local environment variable $env_name is empty\n" unless $token ne '';
        push @parts, "HF_TOKEN=" . shell_quote($token);
    }
    elsif ($OPT{use_remote_hf_token_env}) {
        # Do nothing. Remote process will use remote HF_TOKEN if already set.
    }

    push @parts, "HF_HOME=" . shell_quote("$OPT{default_root}/.hf-home");
    push @parts, "HUGGINGFACE_HUB_CACHE=" . shell_quote("$OPT{default_root}/.hf-cache");

    return @parts ? join(' ', @parts) . ' ' : '';
}

sub remote_dir_exists {
    my ($path) = @_;
    my ($ok, $out) = run_ssh("test -d " . shell_quote($path) . " && echo YES || echo NO");
    return ($ok && $out =~ /YES/) ? 1 : 0;
}

sub remote_file_exists {
    my ($path) = @_;
    my ($ok, $out) = run_ssh("test -f " . shell_quote($path) . " && echo YES || echo NO");
    return ($ok && $out =~ /YES/) ? 1 : 0;
}

sub run_remote_python {
    my ($py) = @_;
    my $cmd = shell_quote($OPT{backend_python}) . " - <<'PY'\n$py\nPY";
    return run_ssh($cmd);
}

sub run_ssh {
    my ($remote_cmd) = @_;
    my $target = "$OPT{backend_ssh_user}\@$OPT{backend_host}";
    my $cmd = "ssh $OPT{backend_ssh_opts} " . shell_quote_local($target) . " " . shell_quote_local($remote_cmd);
    return run_cmd($cmd);
}

sub run_cmd {
    my ($cmd) = @_;
    if ($OPT{dry_run}) {
        print "[DRY-RUN] $cmd\n";
        return (1, '');
    }
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    return ($rc == 0 ? 1 : 0, $out // '');
}

sub print_result {
    my ($ok, $out) = @_;
    print $out if defined $out && $out ne '';
    print "\n" if defined($out) && $out ne '' && $out !~ /\n\z/;
    print "STATUS: " . ($ok ? 'OK' : 'FAIL') . "\n";
}

sub parent_dir {
    my ($path) = @_;
    return dirname($path);
}

sub py_string {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    return "'$s'";
}

sub shell_quote {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub shell_quote_local {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub format_shell_command {
    my (@cmd) = @_;
    my $txt = '';
    for my $i (0 .. $#cmd) {
        my $part = shell_quote_local($cmd[$i]);
        if ($i == 0) {
            $txt .= $part;
        }
        elsif ($cmd[$i] =~ /^--/) {
            $txt .= " \\\n  $part";
        }
        else {
            $txt .= " $part";
        }
    }
    $txt .= "\n";
    return $txt;
}

sub parse_args {
    my ($opt, $argv) = @_;

    for my $arg (@$argv) {
        if ($arg =~ /^--([^=]+)=(.*)$/) {
            my ($k, $v) = ($1, $2);
            $k =~ s/-/_/g;
            die "Unknown option: --$1\n" unless exists $opt->{$k};
            $opt->{$k} = $v;
        }
        elsif ($arg eq '--force') {
            $opt->{force} = 1;
        }
        elsif ($arg eq '--dry-run') {
            $opt->{dry_run} = 1;
        }
        elsif ($arg eq '--use-local-hf-token-env') {
            $opt->{use_local_hf_token_env} = 1;
        }
        elsif ($arg eq '--no-use-remote-hf-token-env') {
            $opt->{use_remote_hf_token_env} = 0;
        }
        elsif ($arg eq '--disable-thinking') {
            $opt->{disable_thinking} = 1;
        }
        elsif ($arg eq '--enable-thinking') {
            $opt->{disable_thinking} = 0;
        }
        elsif ($arg eq '--help' || $arg eq '-h') {
            usage();
            exit 0;
        }
        else {
            die "Unknown argument: $arg\nUse --help for usage.\n";
        }
    }
}

sub usage {
    print <<'USAGE';
Usage:
  perl download_model_on_backend_v022_qwen35b.pl ACTION [options]

Actions:
  list-presets
      Show supported presets for Qwen3.6 FP8, NVFP4, AWQ, etc.

  status
      Check backend Python, vLLM, huggingface_hub, and model root.

  download
      Download a Hugging Face model snapshot onto the backend node.

  check-path
      Check that --dest-dir exists and contains config.json.

  inspect-config
      Print a short config.json summary for --dest-dir.

  print-deploy-command
      Print the current manage_lab_vllm_from_master_v022_qwen35b.pl apply-all command.

  list-local-models
      List model directories under /local_opt/vllm-models that contain config.json.

  remove-local-model
      Remove --dest-dir on backend. Requires --force.

Common options:
  --backend-host=node09
  --backend-ssh-user=root
  --backend-ssh-opts="-o BatchMode=yes -o ConnectTimeout=10"

  --repo-id=ORG/MODEL
  --dest-dir=/local_opt/vllm-models/ORG-MODEL
  --revision=main
  --force

Presets:
  --preset=qwen36_fp8
      repo: Qwen/Qwen3.6-27B-FP8
      served model: qwen3.6-27b-fp8

  --preset=qwen36_nvfp4_text
      repo: sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP
      served model: qwen3.6-27b-text-nvfp4-mtp

  --preset=qwen36_nvfp4
      repo: sakamakismile/Qwen3.6-27B-NVFP4
      served model: qwen3.6-27b-nvfp4

  --preset=qwen36_awq
      repo: cyankiwi/Qwen3.6-27B-AWQ-INT4
      served model: qwen3.6-27b-awq-int4

HF token options:
  --hf-token=hf_xxx
      Direct token. Works, but may appear in shell history.

  --use-local-hf-token-env
      Read local $HF_TOKEN and pass it to the remote download command.

  --hf-token-env=HF_TOKEN
      Local environment variable name to read when using --use-local-hf-token-env.

Current vLLM options:
  --backend-python=/local_opt/vllm-install/.vllm/bin/python
  --default-root=/local_opt/vllm-models

Deploy-command options:
  --manager-script=manage_lab_vllm_from_master_v022_qwen35b.pl
  --setup-dir=SCRIPT_DIR

  --served-model-name=NAME
  --public-model-name=NAME
  --backend-model-name=NAME

  --gpu-memory-utilization=0.85
  --max-model-len=32768
  --max-num-seqs=8
  --max-num-batched-tokens=32768
  --tool-call-parser=qwen3_coder
  --reasoning-parser=qwen3
  --disable-thinking
  --enable-thinking
  --backend-extra-args='...'

Gateway options included in printed deploy command:
  --max-concurrent-per-student=4
  --rpm-limit=60
  --client-timeout=60
  --downstream-timeout=600
  --request-hard-timeout=900
  --max-children=96

Examples:

  Check backend:
    perl download_model_on_backend_v022_qwen35b.pl status

  List presets:
    perl download_model_on_backend_v022_qwen35b.pl list-presets

  Download official Qwen3.6 FP8:
    perl download_model_on_backend_v022_qwen35b.pl download \
      --preset=qwen36_fp8

  Download Qwen3.6 Text NVFP4 MTP:
    perl download_model_on_backend_v022_qwen35b.pl download \
      --preset=qwen36_nvfp4_text

  Download original Qwen3.6 NVFP4:
    perl download_model_on_backend_v022_qwen35b.pl download \
      --preset=qwen36_nvfp4

  Download Qwen3.6 AWQ INT4:
    perl download_model_on_backend_v022_qwen35b.pl download \
      --preset=qwen36_awq

  Download with local HF_TOKEN:
    export HF_TOKEN=hf_xxx
    perl download_model_on_backend_v022_qwen35b.pl download \
      --preset=qwen36_fp8 \
      --use-local-hf-token-env

  Print deployment command for already-downloaded FP8:
    perl download_model_on_backend_v022_qwen35b.pl print-deploy-command \
      --preset=qwen36_fp8

  Check downloaded path:
    perl download_model_on_backend_v022_qwen35b.pl check-path \
      --preset=qwen36_fp8

  List downloaded models:
    perl download_model_on_backend_v022_qwen35b.pl list-local-models
USAGE
}
