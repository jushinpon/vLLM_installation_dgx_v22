#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);

# =============================================================================
# test_vllm_ps_v022_qwen35b_a3b.pl
#
# PowerShell-based vLLM/OpenAI-compatible endpoint tester.
#
# Updated for current lab deployment:
#   Backend installer : install_vllm-v022.sh
#   Backend deployer  : deploy_vllm4dgx_v022_qwen35b.pl
#   Backend smoke test: smoke_test_vllm_v022_qwen35b_a3b.sh
#   Gateway deployer  : deploy_lab_vllm_gateway_v022_qwen35b.pl
#   Master orchestrator:
#       manage_lab_vllm_from_master_v022_qwen35b.pl
#
# Current student-facing gateway:
#   Base URL : http://MASTER_PUBLIC_IP:9000/v1
#   Model    : qwen3.5-35b-a3b
#   API key  : student token from gateway add-student/list-students
#
# Why max_tokens default is 512:
#   Qwen3.5 may put thinking text in the "reasoning" field first.
#   Small values such as 8, 64, or 128 can produce:
#       content = null
#       finish_reason = length
#   512 is enough for a simple "OK" test in your current setup.
# =============================================================================

my $base_url         = '';
my $api_key          = '';
my $model            = 'qwen3.6-35b-a3b-fp8';
my $timeout_sec      = 300;
my $retries          = 3;
my $retry_wait       = 5;
my $max_tokens       = 512;
my $temperature      = 0;
my $expect_substring = 'OK';
my $allow_no_api_key = 0;
my $skip_chat        = 0;
my $show_raw         = 0;

for my $arg (@ARGV) {
    if ($arg =~ /^--base-url=(.+)$/) {
        $base_url = $1;
    }
    elsif ($arg =~ /^--api-key=(.*)$/) {
        $api_key = $1;
    }
    elsif ($arg =~ /^--model=(.+)$/) {
        $model = $1;
    }
    elsif ($arg =~ /^--timeout-sec=(\d+)$/) {
        $timeout_sec = $1;
    }
    elsif ($arg =~ /^--retries=(\d+)$/) {
        $retries = $1;
    }
    elsif ($arg =~ /^--retry-wait=(\d+)$/) {
        $retry_wait = $1;
    }
    elsif ($arg =~ /^--max-tokens=(\d+)$/) {
        $max_tokens = $1;
    }
    elsif ($arg =~ /^--temperature=([0-9.]+)$/) {
        $temperature = $1;
    }
    elsif ($arg =~ /^--expect-substring=(.*)$/) {
        $expect_substring = $1;
    }
    elsif ($arg eq '--allow-no-api-key') {
        $allow_no_api_key = 1;
    }
    elsif ($arg eq '--skip-chat') {
        $skip_chat = 1;
    }
    elsif ($arg eq '--show-raw') {
        $show_raw = 1;
    }
    elsif ($arg eq '--help' || $arg eq '-h') {
        usage();
        exit 0;
    }
    else {
        die "Unknown argument: $arg\nUse --help for usage.\n";
    }
}

if (!$base_url || !$model || (!$api_key && !$allow_no_api_key)) {
    usage();
    exit 1;
}

$base_url =~ s{/$}{};

print "========================================\n";
print "vLLM PowerShell smoke test\n";
print "========================================\n";
print "Base URL          : $base_url\n";
print "Model             : $model\n";
print "API key           : " . ($api_key ? 'enabled' : 'disabled') . "\n";
print "TimeoutSec        : $timeout_sec\n";
print "Retries           : $retries\n";
print "Retry wait        : $retry_wait\n";
print "Chat max_tokens   : $max_tokens\n";
print "Chat temperature  : $temperature\n";
print "Expected substring: " . ($expect_substring eq '' ? '(disabled)' : $expect_substring) . "\n\n";

my ($ok1, $out1) = retry_powershell_models(
    $base_url,
    $api_key,
    $timeout_sec,
    $retries,
    $retry_wait,
);

if (!$ok1) {
    print "FAIL: GET /v1/models\n$out1\n";
    exit 1;
}

print "Raw /v1/models response:\n$out1\n" if $show_raw;

my $models = eval { decode_json($out1) };
if ($@ || ref($models) ne 'HASH' || ref($models->{data}) ne 'ARRAY') {
    print "FAIL: invalid /v1/models response\n$out1\n";
    exit 1;
}

my $found = 0;
my @ids;
for my $m (@{$models->{data}}) {
    my $id = $m->{id} // '';
    push @ids, $id if $id ne '';
    $found = 1 if $id eq $model;
}

print "Detected models: " . join(', ', @ids) . "\n";

if (!$found) {
    print "FAIL: model '$model' not found\n";
    print "Available models: " . join(', ', @ids) . "\n";
    exit 1;
}

print "PASS: model '$model' found\n";

if ($skip_chat) {
    print "SKIP: chat test disabled by --skip-chat\n";
    print "PASS\n";
    exit 0;
}

my ($ok2, $out2) = retry_powershell_chat(
    $base_url,
    $api_key,
    $model,
    $timeout_sec,
    $retries,
    $retry_wait,
    $max_tokens,
    $temperature,
);

if (!$ok2) {
    print "FAIL: POST /v1/chat/completions\n$out2\n";
    exit 1;
}

print "Raw /v1/chat/completions response:\n$out2\n" if $show_raw;

my $chat = eval { decode_json($out2) };
if ($@ || ref($chat) ne 'HASH') {
    print "FAIL: invalid /v1/chat/completions response\n$out2\n";
    exit 1;
}

if (exists $chat->{error}) {
    print "FAIL: chat response contains error\n";
    print encode_pretty($chat), "\n";
    exit 1;
}

my $choice = undef;
if (ref($chat->{choices}) eq 'ARRAY' && @{$chat->{choices}}) {
    $choice = $chat->{choices}[0];
}

if (!$choice || ref($choice) ne 'HASH') {
    print "FAIL: no choices returned\n$out2\n";
    exit 1;
}

my $msg = $choice->{message} || {};
my $reply = ref($msg) eq 'HASH' ? ($msg->{content} // '') : '';
my $reasoning = ref($msg) eq 'HASH' ? ($msg->{reasoning} // '') : '';
my $finish_reason = $choice->{finish_reason} // '';

print "Finish reason: $finish_reason\n";
print "Has reasoning: " . ($reasoning ne '' ? 'yes' : 'no') . "\n";
print "Reply content: " . printable($reply) . "\n";

if ($reply eq '') {
    print "FAIL: empty content reply\n";
    print "Hint: If finish_reason is 'length', increase --max-tokens. Current --max-tokens=$max_tokens\n";
    print "Reasoning preview:\n" . substr($reasoning, 0, 1000) . "\n" if $reasoning ne '';
    exit 1;
}

if ($finish_reason eq 'length') {
    print "FAIL: finish_reason=length. The model ran out of max_tokens before completion.\n";
    print "Hint: Increase --max-tokens, e.g. --max-tokens=1024\n";
    exit 1;
}

if ($expect_substring ne '' && index($reply, $expect_substring) < 0) {
    print "FAIL: reply does not contain expected substring '$expect_substring'\n";
    print "Reply: " . printable($reply) . "\n";
    exit 1;
}

print "PASS: chat works\n";
print "PASS\n";
exit 0;

sub retry_powershell_models {
    my ($base_url, $api_key, $timeout_sec, $retries, $retry_wait) = @_;

    my $last_out = '';
    for my $try (1 .. $retries) {
        print "GET /v1/models attempt $try/$retries ...\n";

        my $ps_models = <<'PS1';
$ErrorActionPreference = "Stop"
$headers = @{}
if ("__API_KEY__" -ne "") {
  $headers["Authorization"] = "Bearer __API_KEY__"
}
$resp = Invoke-RestMethod -Uri "__BASE_URL__/models" -Method Get -Headers $headers -TimeoutSec __TIMEOUT_SEC__
$resp | ConvertTo-Json -Depth 30 -Compress
PS1

        $ps_models =~ s/__API_KEY__/ps_escape($api_key)/ge;
        $ps_models =~ s/__BASE_URL__/ps_escape($base_url)/ge;
        $ps_models =~ s/__TIMEOUT_SEC__/$timeout_sec/g;

        my ($ok, $out) = run_powershell($ps_models);
        return (1, trim_space($out)) if $ok;

        $last_out = $out;
        if ($try < $retries) {
            print "Attempt $try failed. Waiting ${retry_wait}s before retry...\n";
            sleep $retry_wait;
        }
    }

    return (0, $last_out);
}

sub retry_powershell_chat {
    my ($base_url, $api_key, $model, $timeout_sec, $retries, $retry_wait, $max_tokens, $temperature) = @_;

    my $last_out = '';
    for my $try (1 .. $retries) {
        print "POST /v1/chat/completions attempt $try/$retries ...\n";

        my $ps_chat = <<'PS2';
$ErrorActionPreference = "Stop"
$headers = @{
  "Content-Type" = "application/json"
}
if ("__API_KEY__" -ne "") {
  $headers["Authorization"] = "Bearer __API_KEY__"
}

$body = @{
  model = "__MODEL__"
  messages = @(
    @{ role = "user"; content = "Reply with exactly OK." }
  )
  max_tokens = __MAX_TOKENS__
  temperature = __TEMPERATURE__
} | ConvertTo-Json -Depth 20

$resp = Invoke-RestMethod -Uri "__BASE_URL__/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec __TIMEOUT_SEC__
$resp | ConvertTo-Json -Depth 30 -Compress
PS2

        $ps_chat =~ s/__API_KEY__/ps_escape($api_key)/ge;
        $ps_chat =~ s/__BASE_URL__/ps_escape($base_url)/ge;
        $ps_chat =~ s/__MODEL__/ps_escape($model)/ge;
        $ps_chat =~ s/__TIMEOUT_SEC__/$timeout_sec/g;
        $ps_chat =~ s/__MAX_TOKENS__/$max_tokens/g;
        $ps_chat =~ s/__TEMPERATURE__/$temperature/g;

        my ($ok, $out) = run_powershell($ps_chat);
        return (1, trim_space($out)) if $ok;

        $last_out = $out;
        if ($try < $retries) {
            print "Attempt $try failed. Waiting ${retry_wait}s before retry...\n";
            sleep $retry_wait;
        }
    }

    return (0, $last_out);
}

sub run_powershell {
    my ($script) = @_;

    my $tmpdir = $ENV{TEMP} || $ENV{TMP} || '.';
    my $tmp = $tmpdir . "\\vllm_test_v022_qwen35b_a3b_$$.ps1";

    open my $fh, '>', $tmp or die "Cannot write $tmp: $!\n";
    print {$fh} $script;
    close $fh;

    my $ps = 'powershell';
    my $cmd = qq{$ps -NoProfile -ExecutionPolicy Bypass -File "$tmp" 2>&1};

    my $out = `$cmd`;
    my $rc  = $? >> 8;

    unlink $tmp if -f $tmp;

    return ($rc == 0 ? 1 : 0, $out);
}

sub ps_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/`/``/g;
    $s =~ s/"/`"/g;
    return $s;
}

sub trim_space {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub printable {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\r/\\r/g;
    $s =~ s/\n/\\n/g;
    return $s;
}

sub encode_pretty {
    my ($data) = @_;
    return JSON::PP->new->ascii->pretty->encode($data);
}

sub usage {
    print <<'USAGE';
Usage:
  perl test_vllm_ps_v022_qwen35b_a3b.pl --base-url=URL --api-key=TOKEN [options]

Required for student gateway testing:
  --base-url=URL
  --api-key=TOKEN

Required for backend-direct testing without API key:
  --base-url=URL
  --allow-no-api-key

Current lab defaults:
  --model=qwen3.5-35b-a3b
  --max-tokens=512
  --timeout-sec=300
  --retries=3
  --retry-wait=5

Options:
  --model=MODEL
      Default: qwen3.5-35b-a3b

  --timeout-sec=N
      PowerShell Invoke-RestMethod timeout.
      Default: 300

  --retries=N
      Default: 3

  --retry-wait=N
      Default: 5

  --max-tokens=N
      Chat test output budget.
      Default: 512
      Avoid 8, 64, or 128 for Qwen3.5 reasoning output.

  --temperature=FLOAT
      Default: 0

  --expect-substring=TEXT
      Default: OK
      Use --expect-substring= to disable this check.

  --allow-no-api-key
      Allows testing a backend endpoint that does not require Authorization.

  --skip-chat
      Only test /v1/models.

  --show-raw
      Print raw JSON responses.

Examples from Windows PowerShell or CMD:

  Test student-facing gateway:
    perl test_vllm_ps_v022_qwen35b_a3b.pl ^
      --base-url=http://MASTER_PUBLIC_IP:9000/v1 ^
      --api-key=YOUR_STUDENT_TOKEN

  Test with explicit current model:
    perl test_vllm_ps_v022_qwen35b_a3b.pl ^
      --base-url=http://MASTER_PUBLIC_IP:9000/v1 ^
      --api-key=YOUR_STUDENT_TOKEN ^
      --model=qwen3.5-35b-a3b ^
      --max-tokens=512 ^
      --timeout-sec=300

  Test backend directly without API key:
    perl test_vllm_ps_v022_qwen35b_a3b.pl ^
      --base-url=http://node09:8000/v1 ^
      --allow-no-api-key ^
      --model=qwen3.5-35b-a3b

  Only test model list:
    perl test_vllm_ps_v022_qwen35b_a3b.pl ^
      --base-url=http://MASTER_PUBLIC_IP:9000/v1 ^
      --api-key=YOUR_STUDENT_TOKEN ^
      --skip-chat
USAGE
}