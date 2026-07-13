#!/usr/bin/env perl
use strict;
use FindBin;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);

my $SETUP_DIR = $FindBin::Bin;
my $NGINX_SCRIPT    = 'deploy_nginx_gateway_v022_qwen35b.pl';
my $GATEWAY_CONFIG  = '/local_opt/lab-vllm-gateway/config/gateway_config.json';
my $BKEND_SETUP = $FindBin::Bin;
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
        'master-cleanup'    => \&master_cleanup,
        'install-watchdog'  => \&install_watchdog,
        'uninstall-watchdog'=> \&uninstall_watchdog,

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

    master_cleanup() if $OPT{with_cleanup};
    install_watchdog() if $OPT{with_watchdog};

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

sub master_cleanup {
    print "=== MASTER NODE CLEANUP ===\n";
    my $ts = strftime('%Y%m%d_%H%M%S', localtime);
    my $backup_dir = "/root/codex_backups_cluster195/$ts";
    system("mkdir -p $backup_dir");

    for my $f ('/etc/hosts', '/etc/hostname', '/etc/mail/sendmail.mc', '/etc/mail/sendmail.cf') {
        system("cp -a $f $backup_dir/") if -f $f;
    }

    my $hosts = '/etc/hosts';
    open my $fh, '<', $hosts or die "Cannot read $hosts: $!\n";
    my @lines = <$fh>;
    close $fh;
    my $fixed;
    my $found;
    my $master_ip = (split ' ', `hostname -I 2>/dev/null`)[0]
        or die "Cannot detect master IP via hostname -I\n";
    for (@lines) {
        if (/^\s*\Q$master_ip\E\s+master\s*$/) {
            $_ = "$master_ip master.localdomain master\n";
            $found++;
        }
        elsif (/^\s*\Q$master_ip\E\s+.*master/) {
            $found++;
        }
    }
    unless ($found) {
        push @lines, "$master_ip master.localdomain master\n";
    }
    open $fh, '>', $hosts or die "Cannot write $hosts: $!\n";
    print $fh @lines;
    close $fh;
    print "  /etc/hosts updated\n";

    system('systemctl disable --now slurmd 2>/dev/null || true');
    system('systemctl reset-failed slurmd 2>/dev/null || true');

    for my $unit (qw(
        pmlogger.service pmlogger_daily.timer pmlogger_check.timer
        pmlogger_daily-poll.timer pmlogger_daily-poll.service
        pmcd.service pmie.service pmie_daily.timer pmie_check.timer
    )) {
        system("systemctl disable --now $unit 2>/dev/null || true");
        system("systemctl reset-failed $unit 2>/dev/null || true");
    }
    print "  slurmd and PCP units disabled\n";
    print "  Backup: $backup_dir\n";
    print "MASTER CLEANUP OK\n";
}

sub install_watchdog {
    print "=== INSTALL WATCHDOG ===\n";

    my $ts = strftime('%Y%m%d_%H%M%S', localtime);
    my $backup_dir = "/root/codex_backups_vllm_watchdog/$ts";
    system("mkdir -p $backup_dir");

    my $watchdog   = '/usr/local/sbin/vllm_qwen35b_watchdog.sh';
    my $cron_file  = '/etc/cron.d/vllm_qwen35b_watchdog';
    my $logrotate  = '/etc/logrotate.d/vllm_qwen35b_watchdog';

    for my $f ($watchdog, $cron_file, $logrotate) {
        system("cp -a $f $backup_dir/") if -f $f;
    }
    system("crontab -l > $backup_dir/root_crontab.txt 2>/dev/null || true");

    my $bh   = $OPT{backend_host};
    my $bp   = $OPT{backend_port};
    my $mid  = $OPT{model_id};
    my $smn  = $OPT{served_model_name};
    my $watchdog_language_only = $OPT{language_model_only} ? 1 : 0;
    my $watchdog_thinking      = $OPT{disable_thinking} ? 'disabled' : 'default';
    my $watchdog_extra_args    = '';
    $watchdog_extra_args .= "      --no-language-model-only \\\n" if !$OPT{language_model_only};
    $watchdog_extra_args .= "      --limit-mm-per-prompt=" . shell_quote($OPT{limit_mm_per_prompt}) . " \\\n"
        if $OPT{limit_mm_per_prompt};
    $watchdog_extra_args .= "      --disable-thinking \\\n" if $OPT{disable_thinking};

    open my $fh, '>', $watchdog or die "Cannot write $watchdog: $!\n";
    print $fh <<"WATCHDOG";
#!/usr/bin/env bash
set -u

LOCK_FILE="/run/vllm_qwen35b_watchdog.lock"
LOG_FILE="/var/log/vllm_qwen35b_watchdog.log"
STATE_DIR="/var/lib/vllm_qwen35b_watchdog"
FAIL_FILE="\$STATE_DIR/fail_count"
LAST_RESTART_FILE="\$STATE_DIR/last_restart_epoch"

SETUP_DIR="$SETUP_DIR"
MANAGER="\$SETUP_DIR/manage_lab_vllm_nginx_from_master_v022_qwen35b.pl"
BACKEND_HOST="$bh"
BACKEND_PORT="$bp"
MODEL_ID="$mid"
SERVED_MODEL="$smn"

FAIL_THRESHOLD=5
RESTART_COOLDOWN_SEC=900
PROBE_TIMEOUT_SEC=35
RESTART_TIMEOUT_SEC=1200

mkdir -p "\$STATE_DIR"
touch "\$LOG_FILE"

exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  printf '[%s] %s\n' "\$(date '+%F %T %Z')" "\$*" >> "\$LOG_FILE"
}

read_int_file() {
  local f="\$1"
  if [ -f "\$f" ]; then
    tr -cd '0-9' < "\$f"
  else
    printf '0'
  fi
}

probe_backend_generation() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "\$BACKEND_HOST" \\
    BACKEND_PORT="\$BACKEND_PORT" SERVED_MODEL="\$SERVED_MODEL" PROBE_TIMEOUT_SEC="\$PROBE_TIMEOUT_SEC" \\
    'python3 - <<'"'"'PY'"'"'
import json
import os
import sys
import time
import urllib.request

port = os.environ.get("BACKEND_PORT", "8000")
model = os.environ.get("SERVED_MODEL", "qwen3.6-35b-a3b-fp8")
timeout = int(os.environ.get("PROBE_TIMEOUT_SEC", "35"))
base = f"http://127.0.0.1:{port}"

def fail(msg):
    print("PROBE_FAIL", msg)
    sys.exit(1)

try:
    t0 = time.time()
    with urllib.request.urlopen(base + "/health", timeout=8) as r:
        if r.status != 200:
            fail(f"health_http={r.status}")

    with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
        data = json.loads(r.read().decode("utf-8", "replace"))
    model_ids = [m.get("id", "") for m in data.get("data", [])]
    if model not in model_ids:
        fail("model_not_listed=" + ",".join(model_ids))

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply exactly with: OK"}],
        "max_tokens": 8,
        "temperature": 0,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        base + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode("utf-8", "replace"))
    content = (body["choices"][0]["message"].get("content") or "").strip()
    if "OK" not in content.upper():
        fail("unexpected_content=" + content[:120])

    print("PROBE_OK elapsed_sec=%.2f content=%s" % (time.time() - t0, content[:120]))
    sys.exit(0)
except Exception as e:
    fail(type(e).__name__ + ": " + str(e))
PY'
}

restart_backend() {
  if [ ! -f "\$MANAGER" ]; then
    log "RESTART_ABORT manager_not_found path=\$MANAGER"
    return 1
  fi

  log "RESTART_BEGIN backend=\$BACKEND_HOST:\$BACKEND_PORT model=\$SERVED_MODEL max_model_len=131072 language_only=$watchdog_language_only thinking=$watchdog_thinking"
  (
    cd "\$SETUP_DIR" &&
    timeout "\$RESTART_TIMEOUT_SEC" perl "\$MANAGER" backend-restart \\
      --backend-host="\$BACKEND_HOST" \\
      --backend-port="\$BACKEND_PORT" \\
      --model-id="\$MODEL_ID" \\
      --served-model-name="\$SERVED_MODEL" \\
      --gpu-memory-utilization=0.85 \\
      --max-model-len=131072 \\
      --max-num-batched-tokens=16384 \\
      --max-num-seqs=4 \\
      --tool-call-parser=qwen3_coder \\
      --reasoning-parser=qwen3 \\
$watchdog_extra_args      --smoke-test-after-start
  ) >> "\$LOG_FILE" 2>&1
  local rc=\$?
  date +%s > "\$LAST_RESTART_FILE"
  if [ "\$rc" -eq 0 ]; then
    echo 0 > "\$FAIL_FILE"
    log "RESTART_OK"
  else
    log "RESTART_FAIL rc=\$rc"
  fi
  return "\$rc"
}

probe_output="\$(probe_backend_generation 2>&1)"
probe_rc=\$?

if [ "\$probe_rc" -eq 0 ]; then
  echo 0 > "\$FAIL_FILE"
  log "\$probe_output"
  exit 0
fi

fail_count="\$(read_int_file "\$FAIL_FILE")"
fail_count="\${fail_count:-0}"
fail_count=\$((fail_count + 1))
echo "\$fail_count" > "\$FAIL_FILE"
log "PROBE_FAIL count=\$fail_count/\$FAIL_THRESHOLD detail=\$probe_output"

if [ "\$fail_count" -lt "\$FAIL_THRESHOLD" ]; then
  exit 0
fi

now="\$(date +%s)"
last_restart="\$(read_int_file "\$LAST_RESTART_FILE")"
last_restart="\${last_restart:-0}"
since_restart=\$((now - last_restart))

if [ "\$last_restart" -gt 0 ] && [ "\$since_restart" -lt "\$RESTART_COOLDOWN_SEC" ]; then
  log "RESTART_SKIPPED cooldown_active seconds_since_restart=\$since_restart cooldown=\$RESTART_COOLDOWN_SEC"
  exit 0
fi

restart_backend
exit \$?
WATCHDOG
    close $fh;
    chmod 0755, $watchdog or die "chmod $watchdog: $!\n";

    open $fh, '>', $cron_file or die "Cannot write $cron_file: $!\n";
    print $fh <<'CRON';
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# vLLM generation watchdog for node13 Qwen backend.
# Runs a real /v1/chat/completions smoke test. Restarts backend after 3 consecutive failures.
*/2 * * * * root /usr/local/sbin/vllm_qwen35b_watchdog.sh
CRON
    close $fh;
    chmod 0644, $cron_file or die "chmod $cron_file: $!\n";

    open $fh, '>', $logrotate or die "Cannot write $logrotate: $!\n";
    print $fh <<'LOGROTATE';
/var/log/vllm_qwen35b_watchdog.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
    close $fh;
    chmod 0644, $logrotate or die "chmod $logrotate: $!\n";

    print "  Watchdog:  $watchdog\n";
    print "  Cron:      $cron_file\n";
    print "  Logrotate: $logrotate\n";
    print "  Backup:    $backup_dir\n";
    print "INSTALL WATCHDOG OK\n";
}

sub uninstall_watchdog {
    print "=== UNINSTALL WATCHDOG ===\n";
    my $ts = strftime('%Y%m%d_%H%M%S', localtime);
    my $backup_dir = "/root/codex_backups_vllm_watchdog_uninstall/$ts";
    system("mkdir -p $backup_dir");

    for my $f ('/usr/local/sbin/vllm_qwen35b_watchdog.sh', '/etc/cron.d/vllm_qwen35b_watchdog', '/etc/logrotate.d/vllm_qwen35b_watchdog') {
        if (-f $f) {
            system("cp -a $f $backup_dir/");
            unlink $f or warn "Cannot remove $f: $!\n";
            print "  Removed $f\n";
        }
    }
    for my $d ('/var/log/vllm_qwen35b_watchdog.log', '/var/lib/vllm_qwen35b_watchdog', '/run/vllm_qwen35b_watchdog.lock') {
        unlink $d if -f $d;
    }
    rmdir '/var/lib/vllm_qwen35b_watchdog' if -d '/var/lib/vllm_qwen35b_watchdog';
    print "  Backup: $backup_dir\n";
    print "UNINSTALL WATCHDOG OK\n";
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
        elsif ($_ eq '--with-cleanup') { $OPT{with_cleanup} = 1 }
        elsif ($_ eq '--with-watchdog') { $OPT{with_watchdog} = 1 }
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
  apply-all                  Backend restart + gateway setup [+ --with-cleanup] [+ --with-watchdog]
  restart-all                Restart both backend and gateway
  stop-all                   Stop gateway only

Backend (node13 via SSH):
  backend-start|restart|stop|status
  backend-smoke              Quick health check
  force-kill-backend         Kill all vLLM processes on node13
  master-cleanup             Disable slurmd + PCP; fix /etc/hosts (local)
  install-watchdog           Install vLLM watchdog cron + logrotate (local)
  uninstall-watchdog         Remove watchdog cron + logrotate (local)

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
  --with-cleanup (run master-cleanup before apply-all)
  --with-watchdog (install watchdog before apply-all)

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
