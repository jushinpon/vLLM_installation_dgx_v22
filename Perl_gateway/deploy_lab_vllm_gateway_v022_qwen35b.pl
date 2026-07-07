#!/usr/bin/env perl
use strict;
use FindBin;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Basename qw(dirname basename);
use POSIX qw(strftime WNOHANG);
use Digest::SHA qw(sha256_hex);
use IO::Socket::INET;
use IO::Select;
use Socket qw(SOL_SOCKET SO_RCVTIMEO SO_SNDTIMEO);
use Time::HiRes qw(time sleep);
use Fcntl qw(:flock SEEK_SET);
use Cwd qw(abs_path getcwd);
use HTTP::Tiny;

# =============================================================================
# deploy_lab_vllm_gateway_v022_qwen35b.pl
#
# MASTER-side lab gateway for a DGX Spark / GB10 vLLM backend on node09.
#
# Current backend stack:
#   Installer          : install_vllm-v022.sh
#   Backend deployer   : deploy_vllm4dgx_v022_qwen35b.pl
#   Smoke test         : smoke_test_vllm_v022_qwen35b_a3b.sh
#   Backend model      : Qwen/Qwen3.5-35B-A3B
#   Served model name  : qwen3.5-35b-a3b
#   Backend endpoint   : http://node09:8000/v1
#
# What this gateway does:
#   - Gives each student a separate API token.
#   - Accepts OpenAI-compatible requests on the master node.
#   - Authenticates and rate-limits students.
#   - Limits concurrent requests per student using .slot files.
#   - Supports global limits and optional per-student overrides:
#       * max_concurrent
#       * rpm_limit
#   - Forwards requests to the real node09 vLLM backend.
#   - Optionally rewrites JSON "model" field to the backend model name.
#   - Provides /healthz for simple gateway/backend checks.
#
# Main actions:
#   setup-master
#   add-student
#   set-student-limits
#   remove-student
#   list-students
#   start
#   stop
#   restart
#   status
#   run
#   test-backend
#
# Typical setup:
#   perl deploy_lab_vllm_gateway_v022_qwen35b.pl setup-master \
#     --backend-host=node09 \
#     --backend-port=8000 \
#     --gateway-host=0.0.0.0 \
#     --gateway-port=9000 \
#     --public-model-name=qwen3.5-35b-a3b \
#     --backend-model-name=qwen3.5-35b-a3b \
#     --max-concurrent-per-student=4 \
#     --rpm-limit=60
#
# Add normal student using global limits:
#   perl deploy_lab_vllm_gateway_v022_qwen35b.pl add-student \
#     --student-id=s001
#
# Add/admin student with per-student overrides:
#   perl deploy_lab_vllm_gateway_v022_qwen35b.pl add-student \
#     --student-id=admin \
#     --student-max-concurrent=6 \
#     --student-rpm-limit=90
#
# Update limits for an existing student:
#   perl deploy_lab_vllm_gateway_v022_qwen35b.pl set-student-limits \
#     --student-id=admin \
#     --student-max-concurrent=6 \
#     --student-rpm-limit=90
#
# Student endpoint:
#   Base URL: http://MASTER_IP:9000/v1
#   Model   : qwen3.5-35b-a3b
#   API key : the token printed by add-student
# =============================================================================

my %OPT = (
    action                      => shift(@ARGV) || 'status',

    # gateway paths
    root                        => '/local_opt/lab-vllm-gateway',

    # current node09 vLLM backend defaults
    backend_host                => 'node09',
    backend_port                => 8000,
    gateway_host                => '0.0.0.0',
    gateway_port                => 9000,

    # If backend vLLM was started with --api-key, set this.
    # Current deploy_vllm4dgx_v022_qwen35b.pl default has no backend API key.
    downstream_api_key          => $ENV{VLLM_BACKEND_API_KEY} || '',

    # Model visible to students and model used on the backend.
    # Usually these are identical.
    public_model_name           => 'qwen3.5-35b-a3b',
    backend_model_name          => 'qwen3.5-35b-a3b',

    # Backward-compatible name used by older configs/scripts.
    served_model_name           => 'qwen3.5-35b-a3b',

    # If enabled, requests to /v1/chat/completions, /v1/completions,
    # /v1/responses, and /v1/embeddings get JSON field model rewritten to
    # backend_model_name. This avoids student-side model-name mistakes.
    rewrite_model_name          => 1,

    # Global per-student rate/concurrency limits.
    # A student can override these in students_tokens.json with:
    #   max_concurrent: N
    #   rpm_limit: N
    rpm_limit                   => 60,
    max_concurrent_per_student  => 2,

    # Optional per-student override values used only for add-student or
    # set-student-limits actions. Empty means inherit global defaults.
    student_max_concurrent      => '',
    student_rpm_limit           => '',
    clear_student_limits        => 0,

    # Gateway robustness settings.
    client_timeout              => 60,
    downstream_timeout          => 600,
    accept_backlog              => 256,
    max_children                => 96,
    request_hard_timeout        => 900,

    # student admin options
    student_id                  => '',
    allow_ip                    => '',
    token                       => '',
);

parse_args(\%OPT, \@ARGV);

# Keep served_model_name as an alias for old commands.
if (defined $OPT{served_model_name} && $OPT{served_model_name} ne '') {
    $OPT{public_model_name}  = $OPT{served_model_name} if !defined($OPT{public_model_name})  || $OPT{public_model_name}  eq '';
    $OPT{backend_model_name} = $OPT{served_model_name} if !defined($OPT{backend_model_name}) || $OPT{backend_model_name} eq '';
}

my $HOSTNAME = sanitize_name(chomped(`hostname`)) || 'unknown-host';
my $SCRIPT_PATH = abs_path_safe($0);

my $CFG_DIR      = File::Spec->catdir($OPT{root}, 'config');
my $RUN_DIR      = File::Spec->catdir($OPT{root}, 'run');
my $LOG_DIR      = File::Spec->catdir($OPT{root}, 'logs');
my $BIN_DIR      = File::Spec->catdir($OPT{root}, 'bin');
my $META_DIR     = File::Spec->catdir($OPT{root}, 'meta');
my $STATE_DIR    = File::Spec->catdir($RUN_DIR,  'state');
my $SLOTS_DIR    = File::Spec->catdir($STATE_DIR, 'student_slots');

my $CFG_FILE     = File::Spec->catfile($CFG_DIR,  'gateway_config.json');
my $TOKENS_FILE  = File::Spec->catfile($CFG_DIR,  'students_tokens.json');
my $PID_FILE     = File::Spec->catfile($RUN_DIR,  'gateway.pid');
my $LOG_FILE     = File::Spec->catfile($LOG_DIR,  'gateway.log');
my $ACCESS_LOG   = File::Spec->catfile($LOG_DIR,  'access.log');
my $LAUNCHER     = File::Spec->catfile($BIN_DIR,  "launch_gateway_$HOSTNAME.sh");
my $REPORT_FILE  = File::Spec->catfile($META_DIR, 'gateway_report.txt');
my $BACKEND_NOTE = File::Spec->catfile($META_DIR, 'backend_vllm_recommendation.txt');

for my $dir ($OPT{root}, $CFG_DIR, $RUN_DIR, $LOG_DIR, $BIN_DIR, $META_DIR, $STATE_DIR, $SLOTS_DIR) {
    make_path($dir) unless -d $dir;
}

main();
exit 0;

# -----------------------------------------------------------------------------
# main actions
# -----------------------------------------------------------------------------

sub main {
    if ($OPT{action} eq 'setup-master') {
        setup_master();
    }
    elsif ($OPT{action} eq 'add-student') {
        add_student();
    }
    elsif ($OPT{action} eq 'set-student-limits') {
        set_student_limits();
    }
    elsif ($OPT{action} eq 'remove-student') {
        remove_student();
    }
    elsif ($OPT{action} eq 'list-students') {
        list_students();
    }
    elsif ($OPT{action} eq 'start') {
        start_gateway();
    }
    elsif ($OPT{action} eq 'stop') {
        stop_gateway();
    }
    elsif ($OPT{action} eq 'restart') {
        stop_gateway();
        start_gateway();
    }
    elsif ($OPT{action} eq 'status') {
        show_status();
    }
    elsif ($OPT{action} eq 'run') {
        run_gateway();
    }
    elsif ($OPT{action} eq 'test-backend') {
        test_backend_from_cli();
    }
    else {
        die "Unknown action: $OPT{action}\nUse: setup-master | add-student | set-student-limits | remove-student | list-students | start | stop | restart | status | run | test-backend\n";
    }
}

# -----------------------------------------------------------------------------
# setup / admin
# -----------------------------------------------------------------------------

sub setup_master {
    die "--backend-host is required\n" unless $OPT{backend_host};

    my %cfg = (
        version                     => 191,
        generated_at                => strftime('%F %T', localtime()),
        hostname                    => $HOSTNAME,
        gateway_host                => $OPT{gateway_host},
        gateway_port                => int($OPT{gateway_port}),
        backend_host                => $OPT{backend_host},
        backend_port                => int($OPT{backend_port}),
        downstream_api_key          => $OPT{downstream_api_key} || '',
        public_model_name           => $OPT{public_model_name},
        backend_model_name          => $OPT{backend_model_name},
        served_model_name           => $OPT{public_model_name},
        rewrite_model_name          => bool_json($OPT{rewrite_model_name}),
        rpm_limit                   => int($OPT{rpm_limit}),
        client_timeout              => int($OPT{client_timeout}),
        downstream_timeout          => int($OPT{downstream_timeout}),
        accept_backlog              => int($OPT{accept_backlog}),
        max_children                => int($OPT{max_children}),
        max_concurrent_per_student  => int($OPT{max_concurrent_per_student}),
        request_hard_timeout        => int($OPT{request_hard_timeout}),
    );

    write_json($CFG_FILE, \%cfg);

    if (!-f $TOKENS_FILE) {
        write_json($TOKENS_FILE, { students => {} });
    }

    write_launcher();
    write_backend_note(\%cfg);

    my $api_key_msg = $cfg{downstream_api_key} ? 'enabled' : 'disabled';
    my $report = <<"TXT";
=== lab vLLM gateway setup complete ===
Config:
  $CFG_FILE
Tokens:
  $TOKENS_FILE
Launcher:
  $LAUNCHER

Students should connect to:
  http://MASTER_PUBLIC_IP:$cfg{gateway_port}/v1

Gateway forwards to backend vLLM:
  http://$cfg{backend_host}:$cfg{backend_port}/v1

Student-visible model name:
  $cfg{public_model_name}

Backend model name:
  $cfg{backend_model_name}

Backend API key:
  $api_key_msg

Global limits:
  rpm_limit                  = $cfg{rpm_limit}
  max_concurrent_per_student = $cfg{max_concurrent_per_student}

Per-student overrides are stored in:
  $TOKENS_FILE

Add normal student:
  perl $SCRIPT_PATH add-student --student-id=s001

Add admin/heavy student with per-student overrides:
  perl $SCRIPT_PATH add-student --student-id=admin --student-max-concurrent=6 --student-rpm-limit=90

Update an existing student's limits:
  perl $SCRIPT_PATH set-student-limits --student-id=admin --student-max-concurrent=6 --student-rpm-limit=90

Start gateway with:
  perl $SCRIPT_PATH start
TXT

    write_text($REPORT_FILE, $report);
    print $report;
}

sub add_student {
    die "--student-id is required\n" unless $OPT{student_id};
    validate_student_limit_options();

    my $db = read_tokens_db();
    my $student = $OPT{student_id};
    my $old = $db->{students}{$student} || {};
    my $token = $OPT{token} || $old->{token} || generate_student_token($student);

    my @allowed_ips = ();
    if (defined $OPT{allow_ip} && $OPT{allow_ip} ne '') {
        @allowed_ips = grep { $_ ne '' } map { trim($_) } split /,/, $OPT{allow_ip};
    }
    elsif (ref($old->{allowed_ips}) eq 'ARRAY') {
        @allowed_ips = @{ $old->{allowed_ips} };
    }

    my %entry = (
        token       => $token,
        enabled     => JSON::PP::true,
        created_at  => $old->{created_at} || strftime('%F %T', localtime()),
        updated_at  => strftime('%F %T', localtime()),
        allowed_ips => \@allowed_ips,
    );

    if ($OPT{clear_student_limits}) {
        # Intentionally do not copy old limits.
    }
    else {
        if ($OPT{student_max_concurrent} ne '') {
            $entry{max_concurrent} = int($OPT{student_max_concurrent});
        }
        elsif (defined $old->{max_concurrent}) {
            $entry{max_concurrent} = int($old->{max_concurrent});
        }

        if ($OPT{student_rpm_limit} ne '') {
            $entry{rpm_limit} = int($OPT{student_rpm_limit});
        }
        elsif (defined $old->{rpm_limit}) {
            $entry{rpm_limit} = int($old->{rpm_limit});
        }
    }

    $db->{students}{$student} = \%entry;
    write_json($TOKENS_FILE, $db);

    print "ADD STUDENT OK\n";
    print "student_id     : $student\n";
    print "token          : $token\n";
    print "allow_ip       : " . (@allowed_ips ? join(',', @allowed_ips) : '(none)') . "\n";
    print "max_concurrent : " . (defined $entry{max_concurrent} ? $entry{max_concurrent} : '(global default)') . "\n";
    print "rpm_limit      : " . (defined $entry{rpm_limit} ? $entry{rpm_limit} : '(global default)') . "\n";
    print "\nStudent OpenAI-compatible settings:\n";
    print "  Base URL : http://MASTER_PUBLIC_IP:" . current_gateway_port() . "/v1\n";
    print "  Model    : " . current_public_model_name() . "\n";
    print "  API key  : $token\n";
}

sub set_student_limits {
    die "--student-id is required\n" unless $OPT{student_id};
    validate_student_limit_options();

    my $db = read_tokens_db();
    my $student = $OPT{student_id};
    die "Student not found: $student\n" unless exists $db->{students}{$student};

    if ($OPT{clear_student_limits}) {
        delete $db->{students}{$student}{max_concurrent};
        delete $db->{students}{$student}{rpm_limit};
    }
    else {
        if ($OPT{student_max_concurrent} ne '') {
            $db->{students}{$student}{max_concurrent} = int($OPT{student_max_concurrent});
        }
        if ($OPT{student_rpm_limit} ne '') {
            $db->{students}{$student}{rpm_limit} = int($OPT{student_rpm_limit});
        }
    }

    $db->{students}{$student}{updated_at} = strftime('%F %T', localtime());
    write_json($TOKENS_FILE, $db);

    my $s = $db->{students}{$student};
    print "SET STUDENT LIMITS OK\n";
    print "student_id     : $student\n";
    print "max_concurrent : " . (defined $s->{max_concurrent} ? $s->{max_concurrent} : '(global default)') . "\n";
    print "rpm_limit      : " . (defined $s->{rpm_limit} ? $s->{rpm_limit} : '(global default)') . "\n";
}

sub remove_student {
    die "--student-id is required\n" unless $OPT{student_id};

    my $db = read_tokens_db();
    delete $db->{students}{$OPT{student_id}};
    write_json($TOKENS_FILE, $db);

    my $dir = student_slot_dir($OPT{student_id});
    remove_tree($dir, { error => \my $err }) if -d $dir;

    print "REMOVE STUDENT OK: $OPT{student_id}\n";
}

sub list_students {
    my $db = read_tokens_db();
    my $students = $db->{students} || {};
    my $cfg = (-f $CFG_FILE) ? read_json($CFG_FILE) : {};
    my $global_max = $cfg->{max_concurrent_per_student} || $OPT{max_concurrent_per_student};
    my $global_rpm = $cfg->{rpm_limit} || $OPT{rpm_limit};

    for my $sid (sort keys %$students) {
        my $s = $students->{$sid};
        my $ips = (@{$s->{allowed_ips} || []}) ? join(',', @{$s->{allowed_ips}}) : '(none)';
        my $max = defined($s->{max_concurrent}) ? $s->{max_concurrent} : "default($global_max)";
        my $rpm = defined($s->{rpm_limit}) ? $s->{rpm_limit} : "default($global_rpm)";
        print "student_id=$sid\n";
        print "  enabled        = " . (($s->{enabled}) ? 'yes' : 'no') . "\n";
        print "  token          = $s->{token}\n";
        print "  allow_ip       = $ips\n";
        print "  max_concurrent = $max\n";
        print "  rpm_limit      = $rpm\n";
        print "  created_at     = " . ($s->{created_at} || '') . "\n";
        print "  updated_at     = " . ($s->{updated_at} || '') . "\n" if defined $s->{updated_at};
    }
}

sub validate_student_limit_options {
    if ($OPT{student_max_concurrent} ne '' && $OPT{student_max_concurrent} !~ /^\d+$/) {
        die "Invalid --student-max-concurrent value: $OPT{student_max_concurrent}\n";
    }
    if ($OPT{student_rpm_limit} ne '' && $OPT{student_rpm_limit} !~ /^\d+$/) {
        die "Invalid --student-rpm-limit value: $OPT{student_rpm_limit}\n";
    }
    if ($OPT{student_max_concurrent} ne '' && int($OPT{student_max_concurrent}) < 1) {
        die "--student-max-concurrent must be >= 1\n";
    }
    if ($OPT{student_rpm_limit} ne '' && int($OPT{student_rpm_limit}) < 1) {
        die "--student-rpm-limit must be >= 1\n";
    }
}

sub write_backend_note {
    my ($cfg) = @_;

    my $key_line = $cfg->{downstream_api_key}
        ? qq{  --api-key=YOUR_BACKEND_VLLM_KEY \\\n}
        : '';

    my $txt = <<"TXT";
=== backend vLLM recommendation for node09 / DGX Spark / GB10 ===

The backend should already be installed by:
  install_vllm-v022.sh

Recommended backend deployment on node09:

  cd /..

  perl deploy_vllm4dgx_v022_qwen35b.pl restart \\
    --host=0.0.0.0 \\
    --port=$cfg->{backend_port} \\
    --served-model-name=$cfg->{backend_model_name} \\
    --tool-call-parser=qwen3_xml \\
    --reasoning-parser=qwen3 \\
    --max-model-len=32768 \\
    --max-num-seqs=16 \\
    --max-num-batched-tokens=32768 \\
    --gpu-memory-utilization=0.90 \\
$key_line    --disable-thinking \\
    --smoke-test-after-start

Do NOT use --gpu-memory-utilization=0.55 or 0.60 with 32768 context for
Qwen/Qwen3.5-35B-A3B. Your previous logs showed insufficient KV cache memory.

Test backend from node09:
  curl http://127.0.0.1:$cfg->{backend_port}/v1/models

Test backend from gateway/master:
  curl http://$cfg->{backend_host}:$cfg->{backend_port}/v1/models

Gateway forwards to:
  http://$cfg->{backend_host}:$cfg->{backend_port}/v1

Student-visible model name:
  $cfg->{public_model_name}
TXT

    write_text($BACKEND_NOTE, $txt);
}

sub write_launcher {
    my $self = abs_path_safe($0);

    my $txt = <<"SH";
#!/usr/bin/env bash
set -euo pipefail
exec perl "$self" run >> "$LOG_FILE" 2>&1
SH

    write_text($LAUNCHER, $txt);
    chmod 0755, $LAUNCHER;
}

sub start_gateway {
    check_file($CFG_FILE, "Config not found: $CFG_FILE");
    check_file($TOKENS_FILE, "Tokens file not found: $TOKENS_FILE");
    check_file($LAUNCHER, "Launcher not found: $LAUNCHER");

    if (pid_running(read_pid())) {
        print "Gateway already running with PID " . read_pid() . "\n";
        return;
    }

    my $cmd = qq{nohup } . shell_quote($LAUNCHER) . qq{ >> } . shell_quote($LOG_FILE) . qq{ 2>&1 < /dev/null & echo \$!};
    my $pid = chomped(capture_cmd(['bash', '-lc', $cmd], 0));
    die "Failed to start gateway. Raw PID output: $pid\n" unless $pid =~ /^\d+$/;

    write_text($PID_FILE, "$pid\n");
    sleep 2;

    if (!pid_running($pid)) {
        print_log_tail(80);
        die "Gateway process exited immediately\n";
    }

    print "START OK\n";
    print "PID: $pid\n";
    print "Log: $LOG_FILE\n";
}

sub stop_gateway {
    my $pid = read_pid();
    if (!$pid || !pid_running($pid)) {
        unlink $PID_FILE if -f $PID_FILE;
        print "Gateway not running\n";
        return;
    }

    kill 'TERM', $pid;
    for (1 .. 20) {
        last unless pid_running($pid);
        sleep 1;
    }

    if (pid_running($pid)) {
        kill 'KILL', $pid;
    }

    unlink $PID_FILE if -f $PID_FILE;
    print "STOP OK\n";
}

sub show_status {
    my $cfg = (-f $CFG_FILE) ? read_json($CFG_FILE) : {};
    my $pid = read_pid();

    print "Hostname   : $HOSTNAME\n";
    print "PID        : " . ($pid || 'none') . "\n";
    print "Running    : " . (pid_running($pid) ? 'yes' : 'no') . "\n";
    print "Config     : " . (-f $CFG_FILE ? $CFG_FILE : 'missing') . "\n";
    print "Tokens     : " . (-f $TOKENS_FILE ? $TOKENS_FILE : 'missing') . "\n";
    print "Log        : $LOG_FILE\n";
    print "Access log : $ACCESS_LOG\n";

    if (%$cfg) {
        print "Gateway    : http://$cfg->{gateway_host}:$cfg->{gateway_port}/v1\n";
        print "Downstream : http://$cfg->{backend_host}:$cfg->{backend_port}/v1\n";
        print "Public mdl : " . ($cfg->{public_model_name} || $cfg->{served_model_name} || '') . "\n";
        print "Backend mdl: " . ($cfg->{backend_model_name} || $cfg->{served_model_name} || '') . "\n";
        print "Rewrite mdl: " . ($cfg->{rewrite_model_name} ? 'yes' : 'no') . "\n";
        print "Backend key: " . ($cfg->{downstream_api_key} ? 'enabled' : 'disabled') . "\n";
        print "Global RPM limit: $cfg->{rpm_limit}\n";
        print "Global per-student concurrent: $cfg->{max_concurrent_per_student}\n";
        print "Client TO  : $cfg->{client_timeout}\n";
        print "Downstream TO: $cfg->{downstream_timeout}\n";
        print "Max children: $cfg->{max_children}\n";
        print "Hard request timeout: $cfg->{request_hard_timeout}\n";

        my $ok_backend = tcp_healthcheck($cfg->{backend_host}, $cfg->{backend_port}, 2);
        print "Backend TCP: " . ($ok_backend ? 'ok' : 'failed') . "\n";
    }
}

sub test_backend_from_cli {
    my $cfg = (-f $CFG_FILE) ? read_json($CFG_FILE) : {
        backend_host => $OPT{backend_host},
        backend_port => int($OPT{backend_port}),
        downstream_api_key => $OPT{downstream_api_key} || '',
    };

    my $url = "http://$cfg->{backend_host}:$cfg->{backend_port}/v1/models";
    my ($status, $body) = simple_http_get($url, $cfg->{downstream_api_key} || '', 10);
    print "Backend URL: $url\n";
    print "HTTP status: $status\n";
    print "$body\n" if defined $body && $body ne '';
    die "Backend test failed\n" unless $status && $status =~ /^2/;
}

# -----------------------------------------------------------------------------
# runtime
# -----------------------------------------------------------------------------

sub run_gateway {
    my $cfg = read_json($CFG_FILE);

    my $server = IO::Socket::INET->new(
        LocalAddr => $cfg->{gateway_host},
        LocalPort => $cfg->{gateway_port},
        Proto     => 'tcp',
        Listen    => ($cfg->{accept_backlog} || $OPT{accept_backlog}),
        Reuse     => 1,
    ) or die "Cannot bind gateway socket on $cfg->{gateway_host}:$cfg->{gateway_port}: $!\n";

    print "Gateway listening on $cfg->{gateway_host}:$cfg->{gateway_port}\n";
    print "Backend: http://$cfg->{backend_host}:$cfg->{backend_port}/v1\n";
    print "Public model: " . ($cfg->{public_model_name} || $cfg->{served_model_name}) . "\n";

    my %children;   # pid => { start => ..., peer_ip => ... }

    $SIG{CHLD} = sub {
        while ((my $kid = waitpid(-1, WNOHANG)) > 0) {
            delete $children{$kid};
        }
    };

    while (1) {
        reap_children(\%children);
        kill_stuck_children(\%children, $cfg->{request_hard_timeout} || $OPT{request_hard_timeout});

        if (scalar(keys %children) >= ($cfg->{max_children} || $OPT{max_children})) {
            sleep 0.1;
            next;
        }

        my $client = $server->accept();
        next unless $client;

        my $peer_ip = eval { $client->peerhost() } || '';
        set_socket_timeouts($client, $cfg->{client_timeout} || $OPT{client_timeout});
        $client->autoflush(1);

        my $pid = fork();
        if (!defined $pid) {
            eval {
                write_http_response(
                    $client, 503, 'Service Unavailable',
                    { 'Content-Type' => 'application/json' },
                    encode_json({ error => 'fork failed' })
                );
            };
            eval { close $client; };
            next;
        }

        if ($pid == 0) {
            eval { close $server; };

            my $ok = eval {
                handle_client($client, $peer_ip, $cfg);
                1;
            };

            if (!$ok) {
                my $err = $@ || 'unknown error';
                chomp $err;
                eval {
                    write_http_response(
                        $client, 500, 'Internal Server Error',
                        { 'Content-Type' => 'application/json' },
                        encode_json({ error => 'internal error', detail => $err })
                    );
                };
                log_access('ERR', $peer_ip, '-', '-', '-', 500, $err, 0);
            }

            eval { close $client; };
            exit 0;
        }
        else {
            $children{$pid} = {
                start   => time(),
                peer_ip => $peer_ip,
            };
            eval { close $client; };
        }
    }
}

sub handle_client {
    my ($client, $peer_ip, $cfg) = @_;

    my $request_start = time();
    my ($method, $path, $version, $headers, $body) =
        read_http_request($client, $cfg->{client_timeout} || $OPT{client_timeout});
    return unless $method;

    # Health endpoint, no auth required.
    if ($path eq '/healthz') {
        my ($ok_backend, $backend_status) = backend_models_health($cfg, 2);
        my $payload = {
            status         => $ok_backend ? 'ok' : 'degraded',
            gateway_host   => $cfg->{gateway_host},
            gateway_port   => $cfg->{gateway_port},
            backend_host   => $cfg->{backend_host},
            backend_port   => $cfg->{backend_port},
            backend_reach  => $ok_backend ? JSON::PP::true : JSON::PP::false,
            backend_status => $backend_status,
            public_model   => ($cfg->{public_model_name} || $cfg->{served_model_name}),
            backend_model  => ($cfg->{backend_model_name} || $cfg->{served_model_name}),
            ts             => strftime('%F %T', localtime()),
        };
        write_http_response(
            $client,
            $ok_backend ? 200 : 503,
            $ok_backend ? 'OK' : 'Service Unavailable',
            { 'Content-Type' => 'application/json' },
            encode_json($payload),
        );
        log_request_done($peer_ip, '-', $method, $path, $ok_backend ? 200 : 503, '', $request_start);
        return;
    }

    if ($path !~ m{^/v1/}) {
        write_http_response(
            $client, 404, 'Not Found',
            { 'Content-Type' => 'application/json' },
            encode_json({ error => 'not found' })
        );
        log_request_done($peer_ip, '-', $method, $path, 404, 'not found', $request_start);
        return;
    }

    my $tokens_db = read_tokens_db();
    my ($student_id, $auth_err) = authenticate_student($tokens_db, $headers, $peer_ip);
    if (!$student_id) {
        write_http_response(
            $client, 401, 'Unauthorized',
            { 'Content-Type' => 'application/json' },
            encode_json({ error => $auth_err || 'unauthorized' })
        );
        log_request_done($peer_ip, '-', $method, $path, 401, $auth_err || 'unauthorized', $request_start);
        return;
    }

    my $effective_rpm_limit = effective_student_limit(
        $tokens_db,
        $student_id,
        'rpm_limit',
        $cfg->{rpm_limit} || $OPT{rpm_limit}
    );
    my $effective_max_concurrent = effective_student_limit(
        $tokens_db,
        $student_id,
        'max_concurrent',
        $cfg->{max_concurrent_per_student} || $OPT{max_concurrent_per_student}
    );

    log_request_start($peer_ip, $student_id, $method, $path);

    if (!allow_request_rpm_file($student_id, $effective_rpm_limit)) {
        write_http_response(
            $client, 429, 'Too Many Requests',
            { 'Content-Type' => 'application/json' },
            encode_json({
                error     => 'rate limit exceeded',
                rpm_limit => int($effective_rpm_limit),
            })
        );
        log_request_done($peer_ip, $student_id, $method, $path, 429, "rpm exceeded limit=$effective_rpm_limit", $request_start);
        return;
    }

    if (!acquire_student_slot($student_id, $effective_max_concurrent)) {
        write_http_response(
            $client, 429, 'Too Many Requests',
            { 'Content-Type' => 'application/json' },
            encode_json({
                error          => 'too many concurrent requests for this student',
                max_concurrent => int($effective_max_concurrent),
            })
        );
        log_request_done($peer_ip, $student_id, $method, $path, 429, "concurrency exceeded limit=$effective_max_concurrent", $request_start);
        return;
    }

    my ($status, $reason, $resp_headers, $resp_body);
    my $ok = eval {
        ($status, $reason, $resp_headers, $resp_body) =
            forward_to_vllm($cfg, $method, $path, $headers, $body);
        1;
    };

    release_student_slot($student_id);

    if (!$ok) {
        my $err = $@ || 'upstream error';
        chomp $err;
        write_http_response(
            $client, 504, 'Gateway Timeout',
            { 'Content-Type' => 'application/json' },
            encode_json({ error => 'gateway timeout', detail => $err })
        );
        log_request_done($peer_ip, $student_id, $method, $path, 504, $err, $request_start);
        return;
    }

    write_http_response($client, $status, $reason, $resp_headers, $resp_body);
    log_request_done($peer_ip, $student_id, $method, $path, $status, '', $request_start);
}

# -----------------------------------------------------------------------------
# request parsing / forwarding
# -----------------------------------------------------------------------------

sub read_http_request {
    my ($client, $timeout) = @_;

    my $request_line = timed_readline($client, $timeout);
    return unless defined $request_line;

    $request_line =~ s/\r?\n$//;
    my ($method, $path, $version) = split /\s+/, $request_line, 3;
    return unless $method && $path && $version;

    my %headers;
    while (1) {
        my $line = timed_readline($client, $timeout);
        die "client header timeout\n" unless defined $line;
        $line =~ s/\r?\n$//;
        last if $line eq '';
        my ($k, $v) = split /:\s*/, $line, 2;
        next unless defined $k;
        $headers{lc $k} = defined $v ? $v : '';
    }

    my $body = '';
    my $len = $headers{'content-length'} || 0;
    if ($len > 0) {
        $body = timed_read_exact($client, $len, $timeout);
    }

    return ($method, $path, $version, \%headers, $body);
}

sub forward_to_vllm {
    my ($cfg, $method, $path, $headers, $body) = @_;

    my $host    = $cfg->{backend_host};
    my $port    = $cfg->{backend_port};
    my $timeout = $cfg->{downstream_timeout} || $OPT{downstream_timeout};

    my $body_to_send = maybe_rewrite_model_json($cfg, $path, $headers, $body);

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    ) or die "Cannot connect downstream $host:$port: $!\n";

    set_socket_timeouts($sock, $timeout);
    $sock->autoflush(1);

    my %fwd_headers = (
        'host' => "$host:$port",
    );

    if (defined $cfg->{downstream_api_key} && $cfg->{downstream_api_key} ne '') {
        $fwd_headers{'authorization'} = "Bearer $cfg->{downstream_api_key}";
    }

    if (defined $headers->{'content-type'} && $headers->{'content-type'} ne '') {
        $fwd_headers{'content-type'} = $headers->{'content-type'};
    }
    if (defined $headers->{'accept'} && $headers->{'accept'} ne '') {
        $fwd_headers{'accept'} = $headers->{'accept'};
    }
    else {
        $fwd_headers{'accept'} = 'application/json';
    }

    my $req = "$method $path HTTP/1.1\r\n";
    for my $k (sort keys %fwd_headers) {
        $req .= ucfirst_header($k) . ": $fwd_headers{$k}\r\n";
    }
    if (defined $body_to_send && length($body_to_send)) {
        $req .= "Content-Length: " . length($body_to_send) . "\r\n";
    }
    $req .= "Connection: close\r\n\r\n";
    $req .= $body_to_send if defined $body_to_send && length($body_to_send);

    my $written = syswrite($sock, $req);
    die "downstream write failed\n" unless defined $written;

    my ($status, $reason, $resp_headers, $resp_body) = read_http_response($sock, $timeout);
    close $sock;

    # Optional model-name rewrite for /v1/models response if public and backend
    # names differ.
    if ($path =~ m{^/v1/models} && ($cfg->{public_model_name} || '') ne '' && ($cfg->{backend_model_name} || '') ne '') {
        $resp_body = maybe_rewrite_models_response($resp_body, $cfg->{backend_model_name}, $cfg->{public_model_name});
    }

    return ($status, $reason, $resp_headers, $resp_body);
}

sub maybe_rewrite_model_json {
    my ($cfg, $path, $headers, $body) = @_;
    return $body unless $cfg->{rewrite_model_name};
    return $body unless defined $body && $body ne '';
    return $body unless $path =~ m{^/v1/(chat/completions|completions|responses|embeddings)};

    my $ct = $headers->{'content-type'} || '';
    return $body unless $ct eq '' || $ct =~ m{application/json}i;

    my $data = eval { decode_json($body) };
    return $body if $@ || ref($data) ne 'HASH';

    my $backend_model = $cfg->{backend_model_name} || $cfg->{served_model_name} || $cfg->{public_model_name};
    return $body unless defined $backend_model && $backend_model ne '';

    $data->{model} = $backend_model;
    return encode_json($data);
}

sub maybe_rewrite_models_response {
    my ($body, $backend_name, $public_name) = @_;
    return $body unless defined $body && $body ne '';
    return $body if $backend_name eq $public_name;

    my $data = eval { decode_json($body) };
    return $body if $@ || ref($data) ne 'HASH';

    if (ref($data->{data}) eq 'ARRAY') {
        for my $m (@{$data->{data}}) {
            next unless ref($m) eq 'HASH';
            if (defined $m->{id} && $m->{id} eq $backend_name) {
                $m->{id} = $public_name;
            }
        }
    }

    return encode_json($data);
}

sub read_http_response {
    my ($sock, $timeout) = @_;

    my $status_line = timed_readline($sock, $timeout);
    die "empty downstream response\n" unless defined $status_line;
    $status_line =~ s/\r?\n$//;

    my (undef, $status, $reason) = split /\s+/, $status_line, 3;
    $status ||= 500;
    $reason ||= 'Upstream Error';

    my %headers;
    while (1) {
        my $line = timed_readline($sock, $timeout);
        die "downstream header timeout\n" unless defined $line;
        $line =~ s/\r?\n$//;
        last if $line eq '';
        my ($k, $v) = split /:\s*/, $line, 2;
        next unless defined $k;
        $headers{lc $k} = defined $v ? $v : '';
    }

    my $body = '';
    if (defined $headers{'content-length'} && $headers{'content-length'} =~ /^\d+$/) {
        $body = timed_read_exact($sock, $headers{'content-length'}, $timeout);
    }
    elsif (defined $headers{'transfer-encoding'} && $headers{'transfer-encoding'} =~ /chunked/i) {
        $body = read_chunked_body($sock, $timeout);
    }
    else {
        my $selector = IO::Select->new($sock);
        my $start = time();
        while ((time() - $start) < $timeout) {
            my @ready = $selector->can_read(1);
            last unless @ready;
            my $buf = '';
            my $n = sysread($sock, $buf, 8192);
            last unless defined $n && $n > 0;
            $body .= $buf;
        }
    }

    my %out_headers = (
        'Content-Type' => ($headers{'content-type'} || 'application/json'),
    );

    return ($status, $reason, \%out_headers, $body);
}

sub read_chunked_body {
    my ($sock, $timeout) = @_;
    my $body = '';

    while (1) {
        my $line = timed_readline($sock, $timeout);
        die "chunked body timeout\n" unless defined $line;
        $line =~ s/\r?\n$//;
        my ($hex) = split /;/, $line, 2;
        $hex =~ s/^\s+|\s+$//g;
        die "invalid chunk size: $line\n" unless $hex =~ /^[0-9a-fA-F]+$/;
        my $size = hex($hex);

        if ($size == 0) {
            while (1) {
                my $trailer = timed_readline($sock, $timeout);
                last unless defined $trailer;
                $trailer =~ s/\r?\n$//;
                last if $trailer eq '';
            }
            last;
        }

        $body .= timed_read_exact($sock, $size, $timeout);
        my $crlf = timed_read_exact($sock, 2, $timeout);
        die "invalid chunk terminator\n" unless $crlf eq "\r\n" || $crlf eq "\n\n";
    }

    return $body;
}

sub write_http_response {
    my ($client, $status, $reason, $headers, $body) = @_;
    $body = '' unless defined $body;

    my $resp = "HTTP/1.1 $status $reason\r\n";
    for my $k (keys %$headers) {
        $resp .= "$k: $headers->{$k}\r\n";
    }
    $resp .= "Content-Length: " . length($body) . "\r\n";
    $resp .= "Connection: close\r\n\r\n";
    $resp .= $body;

    my $written = syswrite($client, $resp);
    die "client write failed\n" unless defined $written;
}

# -----------------------------------------------------------------------------
# auth / limits
# -----------------------------------------------------------------------------

sub authenticate_student {
    my ($db, $headers, $peer_ip) = @_;

    my $auth = $headers->{authorization} || '';
    my $token = '';

    if ($auth =~ /^Bearer\s+(.+)$/i) {
        $token = $1;
    }
    elsif (defined $headers->{'x-lab-token'} && $headers->{'x-lab-token'} ne '') {
        $token = $headers->{'x-lab-token'};
    }

    return ('', 'missing token') if $token eq '';

    my $students = $db->{students} || {};
    for my $sid (keys %$students) {
        my $s = $students->{$sid};
        next unless $s->{enabled};
        next unless defined $s->{token} && $s->{token} eq $token;

        my $ips = $s->{allowed_ips} || [];
        if (@$ips) {
            my $ok = 0;
            for my $ip (@$ips) {
                if ($peer_ip eq $ip) {
                    $ok = 1;
                    last;
                }
            }
            return ('', 'ip not allowed') unless $ok;
        }

        return ($sid, '');
    }

    return ('', 'invalid token');
}

sub effective_student_limit {
    my ($db, $student_id, $key, $default) = @_;
    my $students = $db->{students} || {};
    my $s = $students->{$student_id} || {};

    if (defined $s->{$key} && $s->{$key} =~ /^\d+$/ && int($s->{$key}) > 0) {
        return int($s->{$key});
    }

    return int($default || 1);
}

sub allow_request_rpm_file {
    my ($student_id, $limit) = @_;

    my $file = File::Spec->catfile($STATE_DIR, "rpm_$student_id.json");
    open my $fh, '+>>', $file or return 0;
    flock($fh, LOCK_EX) or return 0;
    seek($fh, 0, SEEK_SET);

    local $/;
    my $txt = <$fh>;
    my $data = {};
    if (defined $txt && $txt =~ /\S/) {
        eval { $data = decode_json($txt); };
        $data = {} if $@ || ref($data) ne 'HASH';
    }

    my $now = time();
    my $bucket = int($now / 60);

    my %clean = ();
    for my $k (keys %$data) {
        $clean{$k} = $data->{$k} if $k >= $bucket - 1;
    }
    $data = \%clean;

    $data->{$bucket} ||= 0;
    if ($data->{$bucket} >= $limit) {
        truncate($fh, 0);
        seek($fh, 0, SEEK_SET);
        print {$fh} encode_json($data);
        close $fh;
        return 0;
    }

    $data->{$bucket}++;
    truncate($fh, 0);
    seek($fh, 0, SEEK_SET);
    print {$fh} encode_json($data);
    close $fh;
    return 1;
}

sub acquire_student_slot {
    my ($student_id, $limit) = @_;

    my $dir = student_slot_dir($student_id);
    make_path($dir) unless -d $dir;

    my $lockfile = File::Spec->catfile($dir, '.lock');
    open my $lfh, '>>', $lockfile or return 0;
    flock($lfh, LOCK_EX) or return 0;

    cleanup_stale_slots_pid_aware($dir);

    my @slots = grep { /^\d+\.slot$/ } map { basename($_) } glob("$dir/*.slot");
    if (@slots >= $limit) {
        close $lfh;
        return 0;
    }

    my $slot = File::Spec->catfile($dir, "$$.slot");
    open my $sfh, '>', $slot or do { close $lfh; return 0; };
    print {$sfh} time() . "\n";
    close $sfh;

    close $lfh;
    return 1;
}

sub cleanup_stale_slots_pid_aware {
    my ($dir) = @_;

    for my $slot (glob("$dir/*.slot")) {
        my $base = basename($slot);
        next unless $base =~ /^(\d+)\.slot$/;
        my $pid = $1;

        # If the gateway child PID no longer exists, the slot is stale.
        # Do not delete a slot only because it is old; long OpenClaw tasks can
        # legitimately run for a while. The parent hard-timeout monitor handles
        # stuck live children.
        if (!kill 0, $pid) {
            unlink $slot;
        }
    }
}

sub release_student_slot {
    my ($student_id) = @_;
    my $slot = File::Spec->catfile(student_slot_dir($student_id), "$$.slot");
    unlink $slot if -f $slot;
}

sub student_slot_dir {
    my ($student_id) = @_;
    return File::Spec->catdir($SLOTS_DIR, sanitize_name($student_id));
}

# -----------------------------------------------------------------------------
# health / timeouts / child supervision
# -----------------------------------------------------------------------------

sub backend_models_health {
    my ($cfg, $timeout) = @_;
    my $url = "http://$cfg->{backend_host}:$cfg->{backend_port}/v1/models";
    my ($status, $body) = simple_http_get($url, $cfg->{downstream_api_key} || '', $timeout || 3);
    return (($status && $status =~ /^2/) ? 1 : 0, $status || 'no response');
}

sub tcp_healthcheck {
    my ($host, $port, $timeout) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    );
    if ($sock) {
        close $sock;
        return 1;
    }
    return 0;
}

sub reap_children {
    my ($children) = @_;
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) {
        delete $children->{$kid};
    }
}

sub kill_stuck_children {
    my ($children, $hard_timeout) = @_;
    my $now = time();
    for my $pid (keys %$children) {
        next unless defined $children->{$pid}{start};
        my $age = $now - $children->{$pid}{start};
        next if $age < $hard_timeout;

        log_access('KILL', $children->{$pid}{peer_ip} || '-', '-', '-', '-', 599,
            "hard timeout exceeded for child $pid age=${age}s", 0);

        kill 'TERM', $pid;
        sleep 0.2;
        kill 'KILL', $pid if pid_running($pid);
        delete $children->{$pid};
    }
}

sub timed_readline {
    my ($fh, $timeout) = @_;
    my $selector = IO::Select->new($fh);
    my $buf = '';

    while (1) {
        my @ready = $selector->can_read($timeout);
        return undef unless @ready;

        my $char = '';
        my $n = sysread($fh, $char, 1);
        return undef unless defined $n && $n > 0;
        $buf .= $char;

        return $buf if $buf =~ /\n\z/;
    }
}

sub timed_read_exact {
    my ($fh, $len, $timeout) = @_;
    my $selector = IO::Select->new($fh);
    my $buf = '';
    my $start = time();

    while (length($buf) < $len) {
        my $remain = $timeout - (time() - $start);
        die "read timeout\n" if $remain <= 0;

        my @ready = $selector->can_read($remain);
        die "read timeout\n" unless @ready;

        my $chunk = '';
        my $want = $len - length($buf);
        my $n = sysread($fh, $chunk, $want > 8192 ? 8192 : $want);
        die "read failed\n" unless defined $n;
        die "unexpected EOF\n" if $n == 0;
        $buf .= $chunk;
    }

    return $buf;
}

sub set_socket_timeouts {
    my ($sock, $seconds) = @_;
    return unless defined $seconds && $seconds > 0;

    my $tv = pack('l!l!', int($seconds), 0);
    eval {
        setsockopt($sock, SOL_SOCKET, SO_RCVTIMEO, $tv);
        setsockopt($sock, SOL_SOCKET, SO_SNDTIMEO, $tv);
    };
}

# -----------------------------------------------------------------------------
# logging
# -----------------------------------------------------------------------------

sub log_request_start {
    my ($ip, $student_id, $method, $path) = @_;
    log_access('START', $ip, $student_id, $method, $path, '-', '', 0);
}

sub log_request_done {
    my ($ip, $student_id, $method, $path, $status, $msg, $request_start) = @_;
    my $dur_ms = int((time() - $request_start) * 1000);
    log_access('DONE', $ip, $student_id, $method, $path, $status, $msg, $dur_ms);
}

sub log_access {
    my ($flag, $ip, $student_id, $method, $path, $status, $msg, $dur_ms) = @_;
    my $line = join("\t",
        strftime('%F %T', localtime()),
        $flag,
        $ip || '-',
        $student_id || '-',
        $method || '-',
        $path || '-',
        defined($status) ? $status : '-',
        defined($dur_ms) ? $dur_ms : 0,
        $msg || '',
    ) . "\n";

    open my $fh, '>>', $ACCESS_LOG or return;
    print {$fh} $line;
    close $fh;
}

sub print_log_tail {
    my ($n) = @_;
    $n ||= 30;
    print "---- gateway log tail ($n lines) ----\n";
    if (-f $LOG_FILE) {
        system('bash', '-lc', "tail -n $n " . shell_quote($LOG_FILE));
    }
    else {
        print "(log not found)\n";
    }
    print "-------------------------------------\n";
}

# -----------------------------------------------------------------------------
# files / json / HTTP / misc
# -----------------------------------------------------------------------------

sub current_gateway_port {
    if (-f $CFG_FILE) {
        my $cfg = eval { read_json($CFG_FILE) } || {};
        return $cfg->{gateway_port} if $cfg->{gateway_port};
    }
    return $OPT{gateway_port};
}

sub current_public_model_name {
    if (-f $CFG_FILE) {
        my $cfg = eval { read_json($CFG_FILE) } || {};
        return $cfg->{public_model_name} || $cfg->{served_model_name} if %$cfg;
    }
    return $OPT{public_model_name} || $OPT{served_model_name};
}

sub simple_http_get {
    my ($url, $api_key, $timeout) = @_;
    my $http = HTTP::Tiny->new(
        timeout => $timeout || 5,
        verify_SSL => 0,
        default_headers => {
            ($api_key ? ('Authorization' => "Bearer $api_key") : ()),
        },
    );
    my $res = $http->get($url);
    return ($res->{status}, $res->{content});
}

sub read_tokens_db {
    return { students => {} } unless -f $TOKENS_FILE;
    return read_json($TOKENS_FILE);
}

sub generate_student_token {
    my ($student_id) = @_;
    my $seed = join('|', time(), $$, rand(), $student_id, $HOSTNAME);
    return sha256_hex($seed);
}

sub ucfirst_header {
    my ($s) = @_;
    my @parts = split /-/, $s;
    @parts = map { ucfirst(lc($_)) } @parts;
    return join('-', @parts);
}

sub write_json {
    my ($file, $data) = @_;
    write_text($file, JSON::PP->new->ascii->pretty->encode($data));
}

sub read_json {
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

sub sanitize_name {
    my ($name) = @_;
    $name = '' unless defined $name;
    $name =~ s{[/:\\\s]+}{-}g;
    $name =~ s/[^A-Za-z0-9._-]/_/g;
    return $name;
}

sub abs_path_safe {
    my ($path) = @_;
    my $abs = abs_path($path);
    return $abs if defined $abs && $abs ne '';
    my $cwd = getcwd();
    return ($path =~ m{^/}) ? $path : File::Spec->catfile($cwd, $path);
}

sub trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub shell_quote {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub chomped {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\r\n]+\z//;
    return $s;
}

sub bool_json {
    my ($v) = @_;
    return $v ? JSON::PP::true : JSON::PP::false;
}

sub check_file {
    my ($path, $msg) = @_;
    die "$msg\n" unless -f $path;
}

sub parse_args {
    my ($opt, $argv) = @_;
    for my $arg (@$argv) {
        if ($arg =~ /^--student-max-concurrent=(\d+)$/) {
            $opt->{student_max_concurrent} = $1;
        }
        elsif ($arg =~ /^--max-concurrent=(\d+)$/) {
            # Alias for add-student / set-student-limits only.
            $opt->{student_max_concurrent} = $1;
        }
        elsif ($arg =~ /^--student-rpm-limit=(\d+)$/) {
            $opt->{student_rpm_limit} = $1;
        }
        elsif ($arg =~ /^--rpm-limit-student=(\d+)$/) {
            $opt->{student_rpm_limit} = $1;
        }
        elsif ($arg =~ /^--([^=]+)=(.*)$/) {
            my ($k, $v) = ($1, $2);
            $k =~ s/-/_/g;
            $opt->{$k} = $v;
        }
        elsif ($arg eq '--no-rewrite-model-name') {
            $opt->{rewrite_model_name} = 0;
        }
        elsif ($arg eq '--rewrite-model-name') {
            $opt->{rewrite_model_name} = 1;
        }
        elsif ($arg eq '--clear-student-limits') {
            $opt->{clear_student_limits} = 1;
        }
        elsif ($arg eq '--help' || $arg eq '-h') {
            print_help();
            exit 0;
        }
        else {
            die "Unknown argument: $arg\nUse --help for usage.\n";
        }
    }
}

sub print_help {
    print <<'EOF';
Usage:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl ACTION [options]

Actions:
  setup-master          Write gateway config for node09 vLLM backend
  add-student           Add or replace a student API token
  set-student-limits    Update per-student max_concurrent / rpm_limit
  remove-student        Remove a student
  list-students         Show student tokens and limits
  start                 Start gateway daemon
  stop                  Stop gateway daemon
  restart               Restart gateway daemon
  status                Show gateway status
  test-backend          Test backend /v1/models from this machine
  run                   Internal daemon action used by launcher

Current defaults:
  backend_host          node09
  backend_port          8000
  gateway_host          0.0.0.0
  gateway_port          9000
  public_model_name     qwen3.5-35b-a3b
  backend_model_name    qwen3.5-35b-a3b
  downstream_api_key    empty by default

Global gateway setup example:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl setup-master \
    --backend-host=node09 \
    --backend-port=8000 \
    --gateway-port=9000 \
    --public-model-name=qwen3.5-35b-a3b \
    --backend-model-name=qwen3.5-35b-a3b \
    --max-concurrent-per-student=4 \
    --rpm-limit=60

Add normal student using global limits:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl add-student --student-id=s001

Add admin/heavy student with per-student overrides:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl add-student \
    --student-id=admin \
    --student-max-concurrent=6 \
    --student-rpm-limit=90

Update an existing student's limits:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl set-student-limits \
    --student-id=jsp \
    --student-max-concurrent=6 \
    --student-rpm-limit=90

Clear an existing student's custom limits so they inherit global defaults:
  perl deploy_lab_vllm_gateway_v022_qwen35b.pl set-student-limits \
    --student-id=jsp \
    --clear-student-limits

Aliases:
  --max-concurrent=N      same as --student-max-concurrent=N
  --rpm-limit-student=N   same as --student-rpm-limit=N

Student OpenAI settings:
  Base URL: http://MASTER_IP:9000/v1
  Model   : qwen3.5-35b-a3b
  API key : token printed by add-student
EOF
}