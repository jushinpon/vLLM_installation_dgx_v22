#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use File::Spec;
use File::Basename qw(dirname basename);
use POSIX qw(strftime);
use HTTP::Tiny;
use Cwd qw(abs_path getcwd);

# =============================================================================
# deploy_vllm4dgx_v022_qwen35b.pl
#
# Run on node09 / DGX Spark / GB10.
#
# Purpose:
#   Manage the current native vLLM installation created by install_vllm-v022.sh.
#   This script generates a vLLM launcher, starts/stops the backend, and checks
#   readiness. It now supports multimodal settings for Qwen3.6 A3B, including:
#
#     --no-language-model-only
#     --limit-mm-per-prompt='{"image":4}'
#
# Important:
#   - For text-only Hermes/OpenClaw, keep default --language-model-only.
#   - For image input, use --no-language-model-only and --limit-mm-per-prompt.
#   - For Qwen3.6 fast non-thinking mode, use --disable-thinking.
# =============================================================================

my %OPT = (
    action                       => shift(@ARGV) || 'status',

    install_root                 => '/local_opt/vllm-install',
    venv_root                    => '/local_opt/vllm-install/.vllm',
    vllm_src_root                => '/local_opt/vllm-install/vllm',

    stack_root                   => '/local_opt/vllm-service-qwen35b',
    cache_root                   => '/local_opt/vllm-cache',
    hf_root                      => '/local_opt/hf-vllm',
    tmp_root                     => '/local_opt/tmp-vllm',

    model_id                     => 'Qwen/Qwen3.6-35B-A3B-FP8',
    served_model_name            => 'qwen3.6-35b-a3b-fp8',

    host                         => '0.0.0.0',
    port                         => 8000,
    dtype                        => 'auto',
    tensor_parallel_size         => 1,
    gpu_memory_utilization       => '0.70',
    max_model_len                => '32768',
    max_num_batched_tokens       => '8192',
    max_num_seqs                 => '16',

    kv_cache_dtype               => '',
    device                       => '',
    generation_config            => '',
    chat_template_content_format => '',
    default_chat_template_kwargs => '',
    disable_thinking             => 0,

    # New multimodal controls.
    language_model_only          => 1,
    limit_mm_per_prompt          => '',
    media_io_kwargs              => '',
    allowed_local_media_path     => '',
    allowed_media_domains        => '',
    mm_processor_kwargs          => '',

    reasoning_parser             => 'qwen3',
    tool_call_parser             => 'qwen3_coder',
    enable_auto_tool_choice      => 1,
    enable_prefix_caching        => 1,
    enable_chunked_prefill       => 1,
    trust_remote_code            => 1,
    force_eager                  => 0,
    num_scheduler_steps          => '',

    api_key                      => $ENV{VLLM_API_KEY} || '',

    startup_timeout              => 2400,
    stop_existing_on_start       => 1,
    smoke_test_after_start       => 0,
    smoke_test_script            => '',
    smoke_test_timeout           => 3000,
    smoke_test_chat              => 1,
    download_model               => 0,
);

parse_args(\%OPT, \@ARGV);
apply_derived_options(\%OPT);

my $HOSTNAME = sanitize_name(chomped(`hostname`)) || 'node09';
my $SCRIPT_DIR = script_dir();

my $VENV_PY  = File::Spec->catfile($OPT{venv_root}, 'bin', 'python');
my $ACTIVATE = File::Spec->catfile($OPT{venv_root}, 'bin', 'activate');
my $VLLM_SO  = File::Spec->catfile($OPT{vllm_src_root}, 'vllm', '_C.abi3.so');

my $SHARED_BIN = File::Spec->catdir($OPT{stack_root}, 'bin');
my $HF_HOME    = File::Spec->catdir($OPT{hf_root}, $HOSTNAME);
my $TMPDIR     = File::Spec->catdir($OPT{tmp_root}, $HOSTNAME);

my $HOST_ROOT = File::Spec->catdir($OPT{stack_root}, 'hosts', $HOSTNAME);
my $HOST_CFG  = File::Spec->catdir($HOST_ROOT, 'config');
my $HOST_LOG  = File::Spec->catdir($HOST_ROOT, 'logs');
my $HOST_RUN  = File::Spec->catdir($HOST_ROOT, 'run');
my $HOST_META = File::Spec->catdir($HOST_ROOT, 'meta');

my $REPORT_TXT = File::Spec->catfile($HOST_META, 'compatibility_report.txt');
my $CONFIG_JS  = File::Spec->catfile($HOST_CFG,  'deployment.json');
my $ENV_FILE   = File::Spec->catfile($HOST_CFG,  'vllm.env');
my $LAUNCHER   = File::Spec->catfile($SHARED_BIN, "launch_vllm_v022_qwen35b_$HOSTNAME.sh");
my $PID_FILE   = File::Spec->catfile($HOST_RUN,  'vllm.pid');
my $LOG_FILE   = File::Spec->catfile($HOST_LOG,  'vllm_server.log');

for my $dir (
    $OPT{stack_root}, $OPT{cache_root}, $OPT{hf_root}, $OPT{tmp_root},
    $SHARED_BIN, $HOST_ROOT, $HOST_CFG, $HOST_LOG, $HOST_RUN, $HOST_META,
    $HF_HOME, $TMPDIR
) {
    make_path($dir) unless -d $dir;
}

main();
exit 0;

sub main {
    my $action = $OPT{action};

    if ($action eq 'start') {
        my $cfg = ensure_runtime_ready(1);
        start_server($cfg);
        run_smoke_test($cfg, 0) if $OPT{smoke_test_after_start};
        print "START OK\n";
    }
    elsif ($action eq 'stop') {
        stop_server();
        print "STOP OK\n";
    }
    elsif ($action eq 'restart') {
        my $cfg = ensure_runtime_ready(1);
        stop_server();
        start_server($cfg);
        run_smoke_test($cfg, 0) if $OPT{smoke_test_after_start};
        print "RESTART OK\n";
    }
    elsif ($action eq 'status') {
        show_status();
    }
    elsif ($action eq 'smoke') {
        my $cfg = ensure_runtime_ready(0);
        run_smoke_test($cfg, 1);
    }
    elsif ($action eq 'help') {
        usage();
    }
    else {
        die "Unknown action: $action\nUse: start | stop | restart | status | smoke | help\n";
    }
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
        elsif ($arg eq '--trust-remote-code') { $opt->{trust_remote_code} = 1; }
        elsif ($arg eq '--no-trust-remote-code') { $opt->{trust_remote_code} = 0; }
        elsif ($arg eq '--force-eager') { $opt->{force_eager} = 1; }
        elsif ($arg eq '--no-force-eager') { $opt->{force_eager} = 0; }
        elsif ($arg eq '--no-stop-existing-on-start') { $opt->{stop_existing_on_start} = 0; }
        elsif ($arg eq '--smoke-test-after-start') { $opt->{smoke_test_after_start} = 1; }
        elsif ($arg eq '--download-model') { $opt->{download_model} = 1; }
        elsif ($arg eq '--no-auto-tool-choice') { $opt->{enable_auto_tool_choice} = 0; }
        elsif ($arg eq '--no-prefix-caching') { $opt->{enable_prefix_caching} = 0; }
        elsif ($arg eq '--no-chunked-prefill') { $opt->{enable_chunked_prefill} = 0; }
        elsif ($arg eq '--no-language-model-only') { $opt->{language_model_only} = 0; }
        elsif ($arg eq '--language-model-only') { $opt->{language_model_only} = 1; }
        elsif ($arg eq '--no-smoke-test-chat') { $opt->{smoke_test_chat} = 0; }
        elsif ($arg eq '--clear-reasoning-parser') { $opt->{reasoning_parser} = ''; }
        elsif ($arg eq '--clear-tool-call-parser') { $opt->{tool_call_parser} = ''; }
        elsif ($arg eq '--disable-thinking') {
            $opt->{disable_thinking} = 1;
            $opt->{default_chat_template_kwargs} = '{"enable_thinking": false}'
                unless defined($opt->{default_chat_template_kwargs}) && $opt->{default_chat_template_kwargs} ne '';
        }
        elsif ($arg eq '--enable-thinking') {
            $opt->{disable_thinking} = 0;
            $opt->{default_chat_template_kwargs} = '';
        }
        elsif ($arg eq '--help' || $arg eq '-h') {
            usage();
            exit 0;
        }
        else {
            die "Unknown argument: $arg\nUse --help for usage.\n";
        }
    }

    validate_options($opt);
}

sub apply_derived_options {
    my ($opt) = @_;
    if ($opt->{disable_thinking}) {
        $opt->{default_chat_template_kwargs} = '{"enable_thinking": false}'
            unless defined($opt->{default_chat_template_kwargs}) && $opt->{default_chat_template_kwargs} ne '';
    }
}

sub validate_options {
    my ($opt) = @_;

    for my $k (qw(port startup_timeout max_model_len max_num_batched_tokens max_num_seqs tensor_parallel_size smoke_test_timeout num_scheduler_steps)) {
        die "Invalid --$k value: $opt->{$k}\n" if defined($opt->{$k}) && $opt->{$k} ne '' && $opt->{$k} !~ /^\d+$/;
    }

    die "Invalid --gpu-memory-utilization value: $opt->{gpu_memory_utilization}\n"
        if defined($opt->{gpu_memory_utilization}) && $opt->{gpu_memory_utilization} ne '' && $opt->{gpu_memory_utilization} !~ /^\d+(?:\.\d+)?$/;

    if ($opt->{kv_cache_dtype} ne '') {
        die "Invalid --kv-cache-dtype. Use fp8, fp8_e4m3, fp8_e5m2, or auto\n"
            unless $opt->{kv_cache_dtype} =~ /^(fp8|fp8_e4m3|fp8_e5m2|auto)$/;
    }

    if ($opt->{device} ne '') {
        die "Invalid --device. Usually use cuda or leave empty.\n"
            unless $opt->{device} =~ /^(cuda|auto|cpu|neuron|tpu|xpu|hpu|openvino)$/;
    }
}

sub usage {
    print <<'USAGE';
Usage:
  perl deploy_vllm4dgx_v022_qwen35b.pl ACTION [options]

Actions:
  start      Start vLLM backend
  stop       Stop vLLM backend
  restart    Restart vLLM backend
  status     Show backend status
  smoke      Run smoke test against this backend

Important multimodal options:
  --no-language-model-only
      Do not pass --language-model-only. Required for image/video/audio input.

  --limit-mm-per-prompt='{"image":4}'
      Allow and limit multimodal inputs per prompt. For example image=1.

  --allowed-local-media-path=/local_opt/vllm-media
  --allowed-media-domains=example.com,example.org
  --media-io-kwargs='{"video":{"num_frames":256,"fps":2}}'
  --mm-processor-kwargs='{"max_image_size":1024}'

Important OpenClaw/Hermes speed option:
  --disable-thinking
      Adds --default-chat-template-kwargs '{"enable_thinking": false}'

Examples:
  Text-only Qwen3.6 A3B FP8:
    perl deploy_vllm4dgx_v022_qwen35b.pl restart \
      --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
      --served-model-name=qwen3.6-35b-a3b-fp8 \
      --gpu-memory-utilization=0.70 \
      --max-model-len=32768 \
      --max-num-seqs=16 \
      --max-num-batched-tokens=8192 \
      --tool-call-parser=qwen3_coder \
      --reasoning-parser=qwen3 \
      --disable-thinking

  Multimodal Qwen3.6 A3B FP8 with one image allowed:
    perl deploy_vllm4dgx_v022_qwen35b.pl restart \
      --model-id=/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8 \
      --served-model-name=qwen3.6-35b-a3b-fp8 \
      --gpu-memory-utilization=0.70 \
      --max-model-len=65536 \
      --max-num-seqs=8 \
      --max-num-batched-tokens=8192 \
      --tool-call-parser=qwen3_coder \
      --reasoning-parser=qwen3 \
      --disable-thinking \
      --no-language-model-only \
      --limit-mm-per-prompt='{"image":4}'
USAGE
}

# =============================================================================
# Runtime validation
# =============================================================================

sub ensure_runtime_ready {
    my ($refresh_runtime) = @_;

    preflight_checks();

    my $probe = decode_json(python_json(python_probe_code()));
    die "vLLM validation failed in current venv\n" unless $probe->{ok};
    die "CUDA is not available to PyTorch/vLLM in current venv\n" unless $probe->{cuda_available};
    die "Expected Triton 3.6.0, got $probe->{triton_version}\n"
        unless ($probe->{triton_version} || '') =~ /^3\.6\.0/;

    # verify_symbol(); # DISABLED for SM120 Blackwell - using moe-backend triton
    verify_api_entrypoint();

    my $gpu = decode_json(python_json(gpu_probe_code()));
    die "No CUDA device detected by PyTorch in current venv\n"
        unless $gpu->{device_count} && $gpu->{device_count} > 0;

    my ($model_arg, $model_source) = resolve_model_location($OPT{model_id});
    my $cfg = derive_server_plan($gpu, $model_arg, $model_source);

    if ($refresh_runtime || !-f $CONFIG_JS) {
        write_runtime_files($cfg, $gpu);
    }

    return $cfg;
}

sub preflight_checks {
    my @lines;
    push @lines, '==== Preflight checks ====';
    push @lines, 'Timestamp: ' . strftime('%F %T', localtime());
    push @lines, 'Host: ' . $HOSTNAME;
    push @lines, 'Kernel: ' . chomped(`uname -srmo`);

    my $arch = chomped(`uname -m`);
    push @lines, "Detected architecture: $arch";
    die "This script is intended for ARM64 / aarch64 DGX Spark nodes. Detected: $arch\n"
        if $arch ne 'aarch64';

    die "Virtualenv python not found at $VENV_PY\n" unless -x $VENV_PY;
    die "Virtualenv activation script not found at $ACTIVATE\n" unless -f $ACTIVATE;
    die "vLLM source root not found at $OPT{vllm_src_root}\n" unless -d $OPT{vllm_src_root};

    push @lines, "Venv python: $VENV_PY";
    push @lines, "vLLM src: $OPT{vllm_src_root}";
    push @lines, "Requested model_id: $OPT{model_id}";
    push @lines, "Requested served_model_name: $OPT{served_model_name}";
    push @lines, "Language model only: " . ($OPT{language_model_only} ? 'yes' : 'no');
    push @lines, "MM limit: " . ($OPT{limit_mm_per_prompt} || '(not passed)');
    push @lines, "Default chat kwargs: " . ($OPT{default_chat_template_kwargs} || '(not passed)');
    push @lines, "Disable thinking: " . ($OPT{disable_thinking} ? 'yes' : 'no');

    write_text($REPORT_TXT, join("\n", @lines) . "\n");
}

sub resolve_model_location {
    my ($model_id) = @_;

    if (defined $model_id && $model_id =~ m{^/}) {
        die "Local model path does not exist: $model_id\n" unless -d $model_id;
        die "Local model path missing config.json: $model_id\n"
            unless -f File::Spec->catfile($model_id, 'config.json');
        return ($model_id, 'local_path');
    }

    return ($model_id, 'hf_repo_id');
}

sub derive_server_plan {
    my ($gpu, $model_arg, $model_source) = @_;
    my $first = $gpu->{devices}[0];
    my $cap   = ($first->{capability} || '');
    my $name  = ($first->{name} || '');
    my $is_gb10 = (($name =~ /GB10/i) || ($cap eq '12.1')) ? 1 : 0;

    die "This deployment script expects NVIDIA GB10 / compute capability 12.1. Got GPU='$name', capability='$cap'\n"
        unless $is_gb10;

    return {
        host                         => $OPT{host},
        port                         => int($OPT{port}),
        model_id                     => $OPT{model_id},
        model_arg                    => $model_arg,
        model_source                 => $model_source,
        served_model_name            => $OPT{served_model_name},
        api_key                      => $OPT{api_key} || '',
        tensor_parallel_size         => int($OPT{tensor_parallel_size} || 1),
        gpu_memory_utilization       => 0 + $OPT{gpu_memory_utilization},
        max_model_len                => int($OPT{max_model_len}),
        max_num_batched_tokens       => int($OPT{max_num_batched_tokens}),
        max_num_seqs                 => int($OPT{max_num_seqs}),
        dtype                        => $OPT{dtype} || 'auto',
        kv_cache_dtype               => $OPT{kv_cache_dtype} || '',
        device                       => $OPT{device} || '',
        generation_config            => $OPT{generation_config} || '',
        chat_template_content_format => $OPT{chat_template_content_format} || '',
        default_chat_template_kwargs => $OPT{default_chat_template_kwargs} || '',
        disable_thinking             => $OPT{disable_thinking} ? JSON::PP::true : JSON::PP::false,
        language_model_only          => $OPT{language_model_only} ? JSON::PP::true : JSON::PP::false,
        limit_mm_per_prompt          => $OPT{limit_mm_per_prompt} || '',
        media_io_kwargs              => $OPT{media_io_kwargs} || '',
        allowed_local_media_path     => $OPT{allowed_local_media_path} || '',
        allowed_media_domains        => $OPT{allowed_media_domains} || '',
        mm_processor_kwargs          => $OPT{mm_processor_kwargs} || '',
        omp_threads                  => calc_omp_threads(),
        trust_remote_code            => $OPT{trust_remote_code} ? JSON::PP::true : JSON::PP::false,
        force_eager                  => $OPT{force_eager} ? JSON::PP::true : JSON::PP::false,
        num_scheduler_steps          => $OPT{num_scheduler_steps} || '',
        enable_auto_tool_choice      => $OPT{enable_auto_tool_choice} ? JSON::PP::true : JSON::PP::false,
        enable_prefix_caching        => $OPT{enable_prefix_caching} ? JSON::PP::true : JSON::PP::false,
        enable_chunked_prefill       => $OPT{enable_chunked_prefill} ? JSON::PP::true : JSON::PP::false,
        reasoning_parser             => $OPT{reasoning_parser} || '',
        tool_call_parser             => $OPT{tool_call_parser} || '',
        hostname                     => $HOSTNAME,
        generated_at                 => strftime('%F %T', localtime()),
        startup_timeout              => int($OPT{startup_timeout}),
        gpu_name                     => $name,
        gpu_capability               => $cap,
        install_root                 => $OPT{install_root},
        venv_root                    => $OPT{venv_root},
        vllm_src_root                => $OPT{vllm_src_root},
    };
}

# =============================================================================
# Runtime files and launcher
# =============================================================================

sub write_runtime_files {
    my ($cfg, $gpu) = @_;

    my %deployment = (
        %$cfg,
        gpu_probe => $gpu,
        paths => {
            launcher   => $LAUNCHER,
            log_file   => $LOG_FILE,
            pid_file   => $PID_FILE,
            env_file   => $ENV_FILE,
            config_js  => $CONFIG_JS,
            report_txt => $REPORT_TXT,
            hf_home    => $HF_HOME,
            tmpdir     => $TMPDIR,
        },
    );

    write_json($CONFIG_JS, \%deployment);
    write_env_file($ENV_FILE, \%deployment);
    write_launcher($LAUNCHER, \%deployment);
}

sub write_env_file {
    my ($file, $cfg) = @_;
    my @lines = (
        "VLLM_HOST=$cfg->{host}",
        "VLLM_PORT=$cfg->{port}",
        "VLLM_MODEL_ID=$cfg->{model_id}",
        "VLLM_MODEL_ARG=$cfg->{model_arg}",
        "VLLM_MODEL_SOURCE=$cfg->{model_source}",
        "VLLM_SERVED_MODEL_NAME=$cfg->{served_model_name}",
        "VLLM_API_KEY=$cfg->{api_key}",
        "VLLM_REASONING_PARSER=$cfg->{reasoning_parser}",
        "VLLM_TOOL_CALL_PARSER=$cfg->{tool_call_parser}",
        "VLLM_DEFAULT_CHAT_TEMPLATE_KWARGS=$cfg->{default_chat_template_kwargs}",
        "VLLM_DISABLE_THINKING=$cfg->{disable_thinking}",
        "VLLM_LANGUAGE_MODEL_ONLY=$cfg->{language_model_only}",
        "VLLM_LIMIT_MM_PER_PROMPT=$cfg->{limit_mm_per_prompt}",
        "VLLM_MEDIA_IO_KWARGS=$cfg->{media_io_kwargs}",
        "VLLM_ALLOWED_LOCAL_MEDIA_PATH=$cfg->{allowed_local_media_path}",
        "VLLM_ALLOWED_MEDIA_DOMAINS=$cfg->{allowed_media_domains}",
        "VLLM_MM_PROCESSOR_KWARGS=$cfg->{mm_processor_kwargs}",
    );
    write_text($file, join("\n", @lines) . "\n");
}

sub write_launcher {
    my ($file, $cfg) = @_;

    my $script = <<"SCRIPT";
#!/usr/bin/env bash
set -euo pipefail

source @{[shell_quote($ACTIVATE)]}
cd @{[shell_quote($cfg->{vllm_src_root})]}
export PYTHONPATH=@{[shell_quote($cfg->{vllm_src_root})]}:\${PYTHONPATH:-}
export HF_HOME=@{[shell_quote($HF_HOME)]}
export HUGGINGFACE_HUB_CACHE=@{[shell_quote("$HF_HOME/hub")]}
export VLLM_CACHE_ROOT=@{[shell_quote("$OPT{cache_root}/$HOSTNAME/vllm")]}
export TMPDIR=@{[shell_quote($TMPDIR)]}
export OMP_NUM_THREADS=@{[shell_quote($cfg->{omp_threads})]}
export MKL_NUM_THREADS=@{[shell_quote($cfg->{omp_threads})]}
export TRITON_PTXAS_PATH="/usr/local/cuda/bin/ptxas"
export TORCH_CUDA_ARCH_LIST="12.1a"
export HF_HUB_ENABLE_HF_TRANSFER="1"
export VLLM_WORKER_MULTIPROC_METHOD="spawn"

CMD=(
  python -m vllm.entrypoints.openai.api_server
  --model @{[shell_quote($cfg->{model_arg})]}
  --served-model-name @{[shell_quote($cfg->{served_model_name})]}
  --host @{[shell_quote($cfg->{host})]}
  --port @{[shell_quote($cfg->{port})]}
  --tensor-parallel-size @{[shell_quote($cfg->{tensor_parallel_size})]}
  --dtype @{[shell_quote($cfg->{dtype})]}
  --gpu-memory-utilization @{[shell_quote($cfg->{gpu_memory_utilization})]}
  --max-model-len @{[shell_quote($cfg->{max_model_len})]}
  --max-num-batched-tokens @{[shell_quote($cfg->{max_num_batched_tokens})]}
  --max-num-seqs @{[shell_quote($cfg->{max_num_seqs})]}
  --uvicorn-log-level info
)
SCRIPT

    $script .= qq{CMD+=(--device } . shell_quote($cfg->{device}) . qq{)\n} if $cfg->{device};
    $script .= qq{CMD+=(--kv-cache-dtype } . shell_quote($cfg->{kv_cache_dtype}) . qq{)\n} if $cfg->{kv_cache_dtype};
    $script .= qq{CMD+=(--generation-config } . shell_quote($cfg->{generation_config}) . qq{)\n} if $cfg->{generation_config};
    $script .= qq{CMD+=(--chat-template-content-format } . shell_quote($cfg->{chat_template_content_format}) . qq{)\n} if $cfg->{chat_template_content_format};
    $script .= qq{CMD+=(--default-chat-template-kwargs } . shell_quote($cfg->{default_chat_template_kwargs}) . qq{)\n} if $cfg->{default_chat_template_kwargs};
    $script .= qq{CMD+=(--limit-mm-per-prompt } . shell_quote($cfg->{limit_mm_per_prompt}) . qq{)\n} if $cfg->{limit_mm_per_prompt};
    $script .= qq{CMD+=(--media-io-kwargs } . shell_quote($cfg->{media_io_kwargs}) . qq{)\n} if $cfg->{media_io_kwargs};
    $script .= qq{CMD+=(--allowed-local-media-path } . shell_quote($cfg->{allowed_local_media_path}) . qq{)\n} if $cfg->{allowed_local_media_path};

    if ($cfg->{allowed_media_domains}) {
        for my $d (split /,/, $cfg->{allowed_media_domains}) {
            $d =~ s/^\s+|\s+$//g;
            next unless $d ne '';
            $script .= qq{CMD+=(--allowed-media-domains } . shell_quote($d) . qq{)\n};
        }
    }

    $script .= qq{CMD+=(--mm-processor-kwargs } . shell_quote($cfg->{mm_processor_kwargs}) . qq{)\n} if $cfg->{mm_processor_kwargs};

    $script .= qq{CMD+=(--trust-remote-code)\n} if $cfg->{trust_remote_code};
    $script .= qq{CMD+=(--enforce-eager)\n} if $cfg->{force_eager};
    $script .= qq{CMD+=(--language-model-only)\n} if $cfg->{language_model_only};
    $script .= qq{CMD+=(--enable-prefix-caching)\n} if $cfg->{enable_prefix_caching};
    $script .= qq{CMD+=(--enable-chunked-prefill)\n} if $cfg->{enable_chunked_prefill};
    $script .= qq{CMD+=(--moe-backend triton)\n};
    $script .= qq{CMD+=(--num-scheduler-steps } . shell_quote($cfg->{num_scheduler_steps}) . qq{)\n} if $cfg->{num_scheduler_steps};

    if ($cfg->{reasoning_parser}) {
        $script .= qq{CMD+=(--reasoning-parser } . shell_quote($cfg->{reasoning_parser}) . qq{)\n};
    }

    if ($cfg->{enable_auto_tool_choice} && $cfg->{tool_call_parser}) {
        $script .= qq{CMD+=(--enable-auto-tool-choice)\n};
        $script .= qq{CMD+=(--tool-call-parser } . shell_quote($cfg->{tool_call_parser}) . qq{)\n};
    }

    $script .= qq{CMD+=(--api-key } . shell_quote($cfg->{api_key}) . qq{)\n} if $cfg->{api_key};

    $script .= <<'SCRIPT';

echo "Starting vLLM OpenAI-compatible server..."
printf 'Command: '
printf '%q ' "${CMD[@]}"
echo

exec "${CMD[@]}"
SCRIPT

    write_text($file, $script);
    chmod 0755, $file;
}

# =============================================================================
# Service management
# =============================================================================

sub start_server {
    my ($cfg) = @_;

    stop_existing_vllm() if $OPT{stop_existing_on_start};

    if (pid_running(read_pid())) {
        print "Server already running with PID " . read_pid() . "\n";
        return;
    }

    unlink $LOG_FILE if -f $LOG_FILE;

    my $cmd = qq{nohup } . shell_quote($LAUNCHER) . qq{ >> } . shell_quote($LOG_FILE) . qq{ 2>&1 < /dev/null & echo \$!};
    my $pid = chomped(capture_cmd(['bash', '-lc', $cmd], 0));

    die "Failed to start vLLM server. Raw PID output: $pid\n" unless $pid =~ /^\d+$/;
    write_text($PID_FILE, "$pid\n");

    my $timeout = $cfg->{startup_timeout} || 2400;
    my $check_host = api_check_host($cfg->{host});
    my $base = "http://$check_host:$cfg->{port}/v1/models";
    my $start = time();
    my $last_tail = -999;

    print "Spawned PID: $pid\n";
    print "Model arg : $cfg->{model_arg}\n";
    print "Served   : $cfg->{served_model_name}\n";
    print "Chat kwargs: " . ($cfg->{default_chat_template_kwargs} || '(not passed)') . "\n";
    print "Thinking  : " . ($cfg->{disable_thinking} ? 'disabled' : 'default') . "\n";
    print "Language-only: " . ($cfg->{language_model_only} ? 'yes' : 'no') . "\n";
    print "MM limit  : " . ($cfg->{limit_mm_per_prompt} || '(not passed)') . "\n";
    print "Waiting for API readiness: $base\n";
    print "Log: $LOG_FILE\n";

    while ((time() - $start) < $timeout) {
        if (wait_for_http($base, 5, $cfg->{api_key})) {
            print "API is ready.\n";
            verify_ready_model($base, $cfg->{api_key}, $cfg->{served_model_name});
            return;
        }

        if (!pid_running($pid)) {
            print "vLLM process exited before readiness.\n";
            print_log_tail(160);
            die "Startup failed.\n";
        }

        my $elapsed = time() - $start;
        print "Still waiting... ${elapsed}s elapsed\n";

        if (($elapsed - $last_tail) >= 60) {
            $last_tail = $elapsed;
            print_log_tail(40);
        }

        sleep 5;
    }

    print_log_tail(160);
    die "vLLM did not become ready within ${timeout}s\n";
}

sub stop_existing_vllm {
    system('bash', '-lc', q{pkill -f "vllm.entrypoints.openai.api_server" >/dev/null 2>&1 || true});
    system('bash', '-lc', q{pkill -f "VLLM::EngineCore" >/dev/null 2>&1 || true});
    system('bash', '-lc', q{pkill -f "/local_opt/vllm-install/.vllm/bin/python" >/dev/null 2>&1 || true});
    sleep 3;
}

sub stop_server {
    my $pid = read_pid();
    if ($pid && pid_running($pid)) {
        kill 'TERM', $pid;
        for (1 .. 45) {
            last unless pid_running($pid);
            sleep 1;
        }
        kill 'KILL', $pid if pid_running($pid);
    }
    unlink $PID_FILE if -f $PID_FILE;
    stop_existing_vllm();
}

sub show_status {
    my $cfg = (-f $CONFIG_JS) ? read_config_json($CONFIG_JS) : {};
    my $pid = read_pid();

    print "Host      : $HOSTNAME\n";
    print "PID file  : " . ($pid || 'none') . "\n";
    print "Running   : " . (pid_running($pid) ? 'yes' : 'no') . "\n";

    if (%$cfg) {
        print "Venv      : $cfg->{venv_root}\n";
        print "Src       : $cfg->{vllm_src_root}\n";
        print "Model ID  : $cfg->{model_id}\n";
        print "Model arg : $cfg->{model_arg}\n";
        print "Model src : $cfg->{model_source}\n";
        print "Served    : $cfg->{served_model_name}\n";
        print "API       : http://$cfg->{host}:$cfg->{port}/v1\n";
        print "GPU util  : $cfg->{gpu_memory_utilization}\n";
        print "Max len   : $cfg->{max_model_len}\n";
        print "Max btok  : $cfg->{max_num_batched_tokens}\n";
        print "Max seqs  : $cfg->{max_num_seqs}\n";
        print "KV dtype  : " . ($cfg->{kv_cache_dtype} || '(not passed)') . "\n";
        print "Device    : " . ($cfg->{device} || '(not passed)') . "\n";
        print "Chat kwargs: " . ($cfg->{default_chat_template_kwargs} || '(not passed)') . "\n";
        print "Thinking  : " . ($cfg->{disable_thinking} ? 'disabled' : 'default') . "\n";
        print "Language-only: " . ($cfg->{language_model_only} ? 'yes' : 'no') . "\n";
        print "MM limit  : " . ($cfg->{limit_mm_per_prompt} || '(not passed)') . "\n";
        print "Tool pars.: " . ($cfg->{tool_call_parser} || '(disabled)') . "\n";
        print "Reasoning : " . ($cfg->{reasoning_parser} || '(disabled)') . "\n";
        print "GPU       : $cfg->{gpu_name}\n" if defined $cfg->{gpu_name};
        print "Cap       : $cfg->{gpu_capability}\n" if defined $cfg->{gpu_capability};
        print "Eager     : " . ($cfg->{force_eager} ? 'yes' : 'no') . "\n";
        print "API key   : " . ($cfg->{api_key} ? 'enabled' : 'disabled') . "\n";
        print "Log       : $LOG_FILE\n";
    }

    if (%$cfg && pid_running($pid)) {
        my $check_host = api_check_host($cfg->{host});
        my $ok = wait_for_http("http://$check_host:$cfg->{port}/v1/models", 2, $cfg->{api_key});
        print "Ready     : " . ($ok ? 'yes' : 'no') . "\n";
    }
}

# =============================================================================
# Smoke test integration
# =============================================================================

sub run_smoke_test {
    my ($cfg, $require_script) = @_;
    my $script = find_smoke_script();

    if (!$script) {
        my $msg = "Smoke-test script not found.";
        die "$msg\n" if $require_script;
        print "[WARN] $msg\n";
        return;
    }

    if ($cfg->{api_key}) {
        print "[WARN] API key is enabled, but smoke-test script may not pass Authorization headers. Skipping smoke test.\n";
        return;
    }

    my $check_host = api_check_host($cfg->{host});
    my @cmd = (
        'bash', $script,
        '--no-start',
        '--keep-server',
        '--install-dir', $cfg->{install_root},
        '--host', $check_host,
        '--port', $cfg->{port},
        '--served-model-name', $cfg->{served_model_name},
        '--model', $cfg->{model_id},
        '--max-wait', $OPT{smoke_test_timeout},
    );
    push @cmd, '--test-chat' if $OPT{smoke_test_chat};

    print "Running smoke test: @cmd\n";
    system(@cmd) == 0 or die "Smoke test failed: @cmd\n";
}

sub find_smoke_script {
    return $OPT{smoke_test_script} if $OPT{smoke_test_script} && -f $OPT{smoke_test_script};

    my @candidates = (
        File::Spec->catfile($SCRIPT_DIR, 'smoke_test_vllm_v022_qwen35b_a3b.sh'),
        File::Spec->catfile($SCRIPT_DIR, 'smoke_test_v022_qwen35b_a3b.sh'),
    );

    for my $p (@candidates) {
        return $p if -f $p;
    }
    return '';
}

# =============================================================================
# Python probes
# =============================================================================

sub python_probe_code {
    return <<'PY';
import json, sys
try:
    import torch
    import triton
    import transformers
    import vllm
    out = {
        "ok": True,
        "python": sys.version,
        "torch_version": getattr(torch, "__version__", None),
        "torch_cuda": getattr(torch.version, "cuda", None),
        "triton_version": getattr(triton, "__version__", None),
        "transformers_version": getattr(transformers, "__version__", None),
        "vllm_version": getattr(vllm, "__version__", None),
        "cuda_available": bool(torch.cuda.is_available()),
        "vllm_file": getattr(vllm, "__file__", None),
    }
except Exception as e:
    out = {"ok": False, "error": str(e)}
print(json.dumps(out))
PY
}

sub gpu_probe_code {
    return <<'PY';
import json, torch
out = {
    "cuda_available": bool(torch.cuda.is_available()),
    "device_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    "devices": [],
}
if torch.cuda.is_available():
    bf16_supported = bool(getattr(torch.cuda, "is_bf16_supported", lambda: False)())
    for i in range(torch.cuda.device_count()):
        p = torch.cuda.get_device_properties(i)
        out["devices"].append({
            "index": i,
            "name": p.name,
            "total_memory_bytes": int(getattr(p, "total_memory", 0)),
            "total_memory_gb": round(float(getattr(p, "total_memory", 0)) / (1024**3), 2),
            "major": int(p.major),
            "minor": int(p.minor),
            "capability": f"{p.major}.{p.minor}",
            "bf16_supported": bf16_supported,
        })
print(json.dumps(out))
PY
}

sub python_json {
    my ($pycode) = @_;
    return capture_shell(qq{python - <<'PY'\n$pycode\nPY});
}

sub python_run {
    my ($cmd) = @_;
    my $full = qq{source } . shell_quote($ACTIVATE) .
               qq{ && cd } . shell_quote($OPT{vllm_src_root}) .
               qq{ && export PYTHONPATH=} . shell_quote("$OPT{vllm_src_root}:" . ($ENV{PYTHONPATH} || '')) .
               qq{ && $cmd};
    run_cmd(['bash', '-lc', $full]);
}

sub capture_shell {
    my ($cmd) = @_;
    my $full = qq{source } . shell_quote($ACTIVATE) .
               qq{ && cd } . shell_quote($OPT{vllm_src_root}) .
               qq{ && export PYTHONPATH=} . shell_quote("$OPT{vllm_src_root}:" . ($ENV{PYTHONPATH} || '')) .
               qq{ && $cmd};
    return capture_cmd(['bash', '-lc', $full], 0);
}

sub verify_symbol {
    die "_C.abi3.so not found at $VLLM_SO\n" unless -f $VLLM_SO;
    my $cmd = qq{nm -D } . shell_quote($VLLM_SO) . qq{ | c++filt | grep -i cutlass_moe_mm_sm100 | grep ' T '};
    my $out = capture_cmd(['bash', '-lc', $cmd], 1);
    die "Required symbol cutlass_moe_mm_sm100 is not defined in _C.abi3.so\n"
        unless defined $out && $out =~ /\sT\s+cutlass_moe_mm_sm100/;
}

sub verify_api_entrypoint {
    python_run(q{python -m vllm.entrypoints.openai.api_server --help >/dev/null});
}

# =============================================================================
# HTTP helpers
# =============================================================================

sub wait_for_http {
    my ($url, $timeout, $api_key) = @_;
    my $http = HTTP::Tiny->new(
        timeout => $timeout || 5,
        verify_SSL => 0,
        default_headers => {
            ($api_key ? ('Authorization' => "Bearer $api_key") : ()),
        },
    );

    my $res = $http->get($url);
    return $res->{success} ? 1 : 0;
}

sub verify_ready_model {
    my ($url, $api_key, $served_model_name) = @_;
    my $http = HTTP::Tiny->new(
        timeout => 10,
        verify_SSL => 0,
        default_headers => {
            ($api_key ? ('Authorization' => "Bearer $api_key") : ()),
        },
    );
    my $res = $http->get($url);
    die "Could not query model list after readiness\n" unless $res->{success};

    my $data = eval { decode_json($res->{content}) } || {};
    my @ids = map { $_->{id} || '' } @{ $data->{data} || [] };
    print "Ready model IDs: " . join(', ', @ids) . "\n";

    die "Expected model '$served_model_name' not found in /v1/models\n"
        if $served_model_name && !grep { $_ eq $served_model_name } @ids;
}

sub api_check_host {
    my ($host) = @_;
    return '127.0.0.1' if !defined($host) || $host eq '' || $host eq '0.0.0.0';
    return $host;
}

# =============================================================================
# Utilities
# =============================================================================

sub print_log_tail {
    my ($n) = @_;
    $n ||= 40;
    print "---- vLLM log tail ($n lines) ----\n";
    if (-f $LOG_FILE) {
        system('bash', '-lc', "tail -n $n " . shell_quote($LOG_FILE));
    } else {
        print "(log not found)\n";
    }
    print "----------------------------------\n";
}

sub build_env_exports {
    my ($h) = @_;
    my @parts;
    for my $k (sort keys %$h) {
        next unless defined $h->{$k};
        push @parts, qq{export $k=} . shell_quote($h->{$k}) . q{;};
    }
    return join(' ', @parts);
}

sub calc_omp_threads {
    my $nproc = chomped(`nproc 2>/dev/null || echo 4`);
    $nproc = 4 unless $nproc =~ /^\d+$/;
    return $nproc >= 8 ? 8 : $nproc;
}

sub sanitize_name {
    my ($name) = @_;
    $name //= '';
    $name =~ s{[/:\\\s]+}{-}g;
    $name =~ s/[^A-Za-z0-9._-]/_/g;
    return $name;
}

sub shell_quote {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub read_pid {
    return '' unless -f $PID_FILE;
    my $pid = chomped(read_file($PID_FILE));
    return $pid;
}

sub pid_running {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/;
    return kill 0, $pid;
}

sub write_json {
    my ($file, $data) = @_;
    write_text($file, JSON::PP->new->ascii->pretty->encode($data));
}

sub read_config_json {
    my ($file) = @_;
    return decode_json(read_file($file));
}

sub read_file {
    my ($file) = @_;
    local $/;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

sub write_text {
    my ($file, $text) = @_;
    make_path(dirname($file)) unless -d dirname($file);
    open my $fh, '>', $file or die "Cannot write $file: $!\n";
    print {$fh} $text;
    close $fh;
}

sub capture_cmd {
    my ($cmd, $allow_fail) = @_;
    my $pid = open my $fh, '-|', @$cmd;
    die "Failed to execute command: @$cmd\n" unless $pid;
    local $/;
    my $out = <$fh>;
    close $fh;
    if (!$allow_fail && $? != 0) {
        die "Command failed (@$cmd): exit=$?\n$out\n";
    }
    return $out // '';
}

sub run_cmd {
    my ($cmd) = @_;
    system(@$cmd) == 0 or die "Command failed: @$cmd\n";
}

sub chomped {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\r\n]+\z//;
    return $s;
}

sub script_dir {
    my $path = abs_path($0) || File::Spec->catfile(getcwd(), basename($0));
    return dirname($path);
}