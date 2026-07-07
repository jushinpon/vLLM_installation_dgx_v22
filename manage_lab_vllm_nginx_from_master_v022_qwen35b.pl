#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);

my $SETUP_DIR       = '/home/dgx-spark-vllm-setup-v022';
my $NGINX_SCRIPT    = 'deploy_nginx_gateway_v022_qwen35b.pl';
my $GATEWAY_CONFIG  = '/local_opt/lab-vllm-gateway/config/gateway_config.json';
my $BKEND_SETUP     = '/home/dgx-spark-vllm-setup-v022';
my $BKEND_SCRIPT    = 'deploy_vllm4dgx_v022_qwen35b.pl';

my %OPT = (
    backend_host           => 'node13',
    backend_port           => 8000,
    backend_ssh_user       => 'root',
    backend_bind_host      => '0.0.0.0',
    gateway_port           => 9000,
    model_id               => '/local_opt/vllm-models/Qwen-Qwen3.6-35B-A3B-FP8',
    served_model_name      => 'qwen3.6-35b-a3b-fp8',
    public_model_name      => 'qwen3.6-35b-a3b-fp8',
    backend_model_name     => 'qwen3.6-35b-a3b-fp8',
    gpu_memory_utilization => '0.85',
    max_model_len          => '131072',
    max_num_batched_tokens => '16384',
    max_num_seqs           => '4',
    reasoning_parser       => 'qwen3',
    tool_call_parser       => 'qwen3_coder',
    disable_thinking       => 1,
    default_chat_template_kwargs => '{"enable_thinking": false}',
    kv_cache_dtype         => '',
    device                 => '',
    language_model_only    => 1,
    limit_mm_per_prompt    => '',
    backend_api_key        => '',
    backend_extra_args     => '',
    smoke_test_after_start => 1,

    # gateway config (written to gateway_config.json)
    max_concurrent_per_student => 6,
    rpm_limit              => 120,
    client_timeout         => 300,
    downstream_timeout     => 600,
    request_hard_timeout   => 900,
    max_children           => 96,
    accept_backlog         => 256,
    rewrite_model_name     => 1,
    skip_backend           => 0,
    vllm_env               => '',
);

my $action = shift @ARGV || 'show';
parse_args(\@ARGV);

sub main {
    my $actions = {
        show                => \&show_all,
        status              => \&show_status,
        'apply-all'         => \&apply_all,
        'restart-all'       => sub { backend_action('restart'); run_nginx('restart') },
        'stop-all'          => sub { run_nginx('stop') },

        'backend-start'     => sub { backend_action('start') },
        'backend-restart'   => sub { backend_action('restart') },
        'backend-stop'      => sub { backend_action('stop') },
        'backend-status'    => sub { backend_action('status') },
        'backend-smoke'     => \&backend_smoke,
        'force-kill-backend'=> \&force_kill_backend,

        'gateway-setup'     => sub { run_nginx('setup') },
        'gateway-start'     => sub { run_nginx('start') },
        'gateway-stop'      => sub { run_nginx('stop') },
        'gateway-restart'   => sub { run_nginx('restart') },
        'gateway-reload'    => sub { run_nginx('reload') },
        'gateway-status'    => sub { run_nginx('status') },

        'add-student'       => sub { run_nginx('add-student', @ARGV) },
        'remove-student'    => sub { run_nginx('remove-student', @ARGV) },
        'set-student-limits'=> sub { run_nginx('set-student-limits', @ARGV) },
        'list-students'     => sub { run_nginx('list-students') },

        help                => \&usage,
    };

    if (my $code = $actions->{$action}) {
        $code->();
    } else {
        die "Unknown action: $action\nUse help for usage.\n";
    }
}

sub show_all {
    my $cfg = read_config();
    my $rpm   = $cfg->{rpm_limit} // $OPT{rpm_limit};
    my $max_c = $cfg->{max_concurrent_per_student} // $OPT{max_concurrent_per_student};
    my $ct    = $cfg->{client_timeout} // $OPT{client_timeout};
    my $dt    = $cfg->{downstream_timeout} // $OPT{downstream_timeout};
    my $ht    = $cfg->{request_hard_timeout} // $OPT{request_hard_timeout};
    print "=== GATEWAY CONFIG ===\n";
    print "  Backend:      http://$OPT{backend_host}:$OPT{backend_port}/v1\n";
    print "  Gateway:      http://MASTER_PUBLIC_IP:$OPT{gateway_port}/v1\n";
    print "  Public model: $OPT{public_model_name}\n";
    print "  RPM limit:    ${rpm}/min per student\n";
    print "  Max concurrent: ${max_c} per student\n";
    print "  Timeouts:     client=${ct}s downstream=${dt}s hard=${ht}s\n\n";

    run_nginx('status');

    print "\n=== VLLM BACKEND ===\n";
    backend_action('status', 1);

    print "\n=== USAGE ===\n";
    print "  Base URL: http://MASTER_PUBLIC_IP:$OPT{gateway_port}/v1\n";
    print "  Model:    $OPT{public_model_name}\n";
    print "  API key:  student token from add-student / list-students\n";
}

sub show_status {
    run_nginx('status');
    print "\n=== VLLM BACKEND ===\n";
    backend_action('status', 1);
}

sub apply_all {
    print "=== APPLY ALL: backend vLLM + nginx gateway ===\n";

    unless ($OPT{skip_backend}) {
        print "\n--- Restarting backend vLLM on $OPT{backend_host} ---\n";
        backend_action('restart');
    }

    print "\n--- Writing gateway config ---\n";
    write_gateway_config();

    print "\n--- Setting up nginx gateway on master ---\n";
    run_nginx('setup');

    print "\nAPPLY ALL OK\n";
    print "  Gateway: http://MASTER_PUBLIC_IP:$OPT{gateway_port}/v1\n";
    print "  Model:   $OPT{public_model_name}\n";
    print "  RPM:     $OPT{rpm_limit}/min per student\n";
    print "  Max concurrent: $OPT{max_concurrent_per_student} per student\n";
}

sub stop_all {
    print "=== STOP ALL ===\n";
    run_nginx('stop');
    print "STOP ALL OK\n";
}

sub backend_action {
    my ($action, $allow_fail) = @_;
    $allow_fail ||= 0;

    my @cmd = ('perl', $BKEND_SCRIPT, $action);

    if ($action eq 'start' || $action eq 'restart') {
        push @cmd, "--host=$OPT{backend_bind_host}",
            "--port=$OPT{backend_port}",
            "--model-id=$OPT{model_id}",
            "--served-model-name=$OPT{served_model_name}",
            "--max-model-len=$OPT{max_model_len}",
            "--max-num-seqs=$OPT{max_num_seqs}",
            "--max-num-batched-tokens=$OPT{max_num_batched_tokens}",
            "--gpu-memory-utilization=$OPT{gpu_memory_utilization}";

        push @cmd, "--tool-call-parser=$OPT{tool_call_parser}" if $OPT{tool_call_parser};
        push @cmd, "--reasoning-parser=$OPT{reasoning_parser}" if $OPT{reasoning_parser};
        push @cmd, "--kv-cache-dtype=$OPT{kv_cache_dtype}" if $OPT{kv_cache_dtype};
        push @cmd, "--device=$OPT{device}" if $OPT{device};
        push @cmd, '--no-language-model-only' if !$OPT{language_model_only};
        push @cmd, "--limit-mm-per-prompt=$OPT{limit_mm_per_prompt}" if $OPT{limit_mm_per_prompt};
        push @cmd, '--disable-thinking' if $OPT{disable_thinking};
        push @cmd, "--api-key=$OPT{backend_api_key}" if $OPT{backend_api_key};
        push @cmd, '--smoke-test-after-start' if $OPT{smoke_test_after_start};
    }

    my $env_prefix = $OPT{vllm_env} ? "$OPT{vllm_env} " : '';
    my $remote = $env_prefix . 'cd ' . shell_quote($BKEND_SETUP) . ' && ' . join(' ', map { shell_quote($_) } @cmd);
    my ($ok, $out) = run_ssh($remote);
    print $out;
    die "Backend action '$action' failed on $OPT{backend_host}\n" if !$ok && !$allow_fail;
}

sub run_ssh {
    my ($remote_cmd) = @_;
    my $target = "$OPT{backend_ssh_user}\@$OPT{backend_host}";
    my $cmd = "ssh -o BatchMode=yes -o ConnectTimeout=10 " . shell_quote($target) . " " . shell_quote($remote_cmd);
    my $out = `$cmd 2>&1`;
    my $rc = $? >> 8;
    return ($rc == 0 ? 1 : 0, $out // '');
}

sub run_nginx {
    my ($subaction, @extra) = @_;
    my $cmd = "cd $SETUP_DIR && perl $NGINX_SCRIPT $subaction @extra";
    print "[+] $cmd\n";
    my $out = `$cmd 2>&1`;
    print $out;
}

sub backend_smoke {
    my $models = `curl -s --connect-timeout 10 http://$OPT{backend_host}:$OPT{backend_port}/v1/models 2>/dev/null`;
    if ($models =~ /"id":\s*"([^"]+)"/) {
        print "Backend OK - model: $1\n";
    } else {
        print "Backend check failed (is vLLM running?)\n$models\n";
    }
}

sub force_kill_backend {
    my $script = q{
set +e
pkill -TERM -f 'vllm.entrypoints.openai.api_server' 2>/dev/null || true
pkill -TERM -f 'VLLM::EngineCore' 2>/dev/null || true
pkill -TERM -f 'python.*vllm' 2>/dev/null || true
sleep 3
pkill -KILL -f 'vllm.entrypoints.openai.api_server' 2>/dev/null || true
pkill -KILL -f 'VLLM::EngineCore' 2>/dev/null || true
echo "Killed vLLM processes on $OPT{backend_host}"
};
    my ($ok, $out) = run_ssh($script);
    print $out;
}

sub write_gateway_config {
    my %cfg = (
        backend_host           => $OPT{backend_host},
        backend_port           => $OPT{backend_port},
        backend_model_name     => $OPT{backend_model_name},
        gateway_host           => '0.0.0.0',
        gateway_port           => $OPT{gateway_port},
        public_model_name      => $OPT{public_model_name},
        served_model_name      => $OPT{served_model_name},
        max_concurrent_per_student => $OPT{max_concurrent_per_student},
        rpm_limit              => $OPT{rpm_limit},
        client_timeout         => $OPT{client_timeout},
        downstream_timeout     => $OPT{downstream_timeout},
        request_hard_timeout   => $OPT{request_hard_timeout},
        max_children           => $OPT{max_children},
        accept_backlog         => $OPT{accept_backlog},
        rewrite_model_name     => $OPT{rewrite_model_name} ? JSON::PP::true : JSON::PP::false,
        downstream_api_key     => $OPT{backend_api_key},
        generated_at           => strftime('%Y-%m-%d %H:%M:%S', localtime),
        version                => 191,
        hostname               => 'master',
    );
    make_path(dirname($GATEWAY_CONFIG));
    open my $fh, '>', $GATEWAY_CONFIG or die "Cannot write $GATEWAY_CONFIG: $!\n";
    print $fh JSON::PP->new->pretty->encode(\%cfg);
    close $fh;
    print "Gateway config written: $GATEWAY_CONFIG\n";
}

sub read_config {
    return {} unless -f $GATEWAY_CONFIG;
    open my $fh, '<', $GATEWAY_CONFIG or return {};
    local $/;
    return decode_json(<$fh>);
}

sub parse_args {
    my ($argv) = @_;
    return unless $argv && @$argv;
    my %alias = (
        max_concurrent => 'max_concurrent_per_student',
        rpm_limit_student => 'rpm_limit',
    );
    for (@$argv) {
        next unless defined $_;
        if (/^--([^=]+)=(.*)$/) {
            my ($k, $v) = ($1, $2);
            $k =~ s/-/_/g;
            $k = $alias{$k} if exists $alias{$k};
            $OPT{$k} = $v if exists $OPT{$k};
        }
        elsif ($_ eq '--skip-backend') { $OPT{skip_backend} = 1 }
        elsif ($_ eq '--disable-thinking') { $OPT{disable_thinking} = 1 }
        elsif ($_ eq '--enable-thinking') { $OPT{disable_thinking} = 0 }
        elsif ($_ eq '--no-language-model-only') { $OPT{language_model_only} = 0 }
        elsif ($_ eq '--language-model-only') { $OPT{language_model_only} = 1 }
        elsif ($_ eq '--rewrite-model-name') { $OPT{rewrite_model_name} = 1 }
        elsif ($_ eq '--no-rewrite-model-name') { $OPT{rewrite_model_name} = 0 }
        elsif ($_ eq '--vllm-allow-long-max-model-len') { $OPT{vllm_env} = 'VLLM_ALLOW_LONG_MAX_MODEL_LEN=1' }
    }
}

sub shell_quote {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub usage {
    print <<"USAGE";
Usage: manage_lab_vllm_nginx_from_master_v022_qwen35b.pl ACTION [options]

Actions:
  show, status               Show all status
  apply-all                  Restart backend vLLM + write gateway config + nginx setup
  restart-all                Restart both backend and gateway
  stop-all                   Stop gateway only

Backend (node13 via SSH):
  backend-start|restart|stop|status
  backend-smoke              Quick health check
  force-kill-backend         Kill all vLLM processes on node13

Gateway (master nginx):
  gateway-setup              Install nginx + generate config
  gateway-start|stop|restart|reload|status

Students:
  add-student                --student-id=ID [--token=TOKEN] [--allow-ip=IP]
  remove-student             --student-id=ID
  set-student-limits         --student-id=ID [--rpm-limit=N] [--max-concurrent=N]
  list-students

Backend options (defaults):
  --model-id=$OPT{model_id}
  --served-model-name=$OPT{served_model_name}
  --gpu-memory-utilization=$OPT{gpu_memory_utilization}
  --max-model-len=$OPT{max_model_len}
  --max-num-seqs=$OPT{max_num_seqs}
  --max-num-batched-tokens=$OPT{max_num_batched_tokens}
  --reasoning-parser=qwen3
  --tool-call-parser=qwen3_coder
  --disable-thinking
  --no-language-model-only (enable multimodal)
  --vllm-allow-long-max-model-len (override model's max_position_embeddings)
  --skip-backend (skip backend restart in apply-all)

Gateway options (written to gateway_config.json):
  --max-concurrent-per-student=$OPT{max_concurrent_per_student}
  --rpm-limit=$OPT{rpm_limit}
  --client-timeout=$OPT{client_timeout}
  --downstream-timeout=$OPT{downstream_timeout}
  --request-hard-timeout=$OPT{request_hard_timeout}
  --max-children=$OPT{max_children}

Example:
  perl manage_lab_vllm_nginx_from_master_v022_qwen35b.pl apply-all \\
    --gpu-memory-utilization=0.85 --max-model-len=320000 \\
    --max-num-seqs=4 --max-num-batched-tokens=320000 \\
    --max-concurrent-per-student=6 --rpm-limit=120 \\
    --client-timeout=300 --downstream-timeout=600
USAGE
}

main();
