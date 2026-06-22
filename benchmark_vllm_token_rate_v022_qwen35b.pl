#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use HTTP::Tiny;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);

# =============================================================================
# benchmark_vllm_token_rate_v022_qwen35b.pl
#
# Purpose:
#   Benchmark token generation rate for the current vLLM v022-style lab setup.
#
# Supports:
#   1. Master lab gateway:
#        http://127.0.0.1:9000/v1
#        http://MASTER_PUBLIC_IP:9000/v1
#
#   2. node09 backend:
#        http://127.0.0.1:8000/v1  when running on node09
#        http://node09:8000/v1     when running from master
#
# Current typical models:
#   qwen3.5-35b-a3b
#   qwen3.6-27b-fp8
#   qwen3.6-35b-a3b-fp8
#
# What it measures:
#   - Non-streaming wall-clock completion time.
#   - completion_tokens from vLLM/OpenAI-compatible usage field.
#   - completion_tokens / wall_time = tokens/sec.
#
# Why non-streaming:
#   - It gives exact completion_tokens from the API response.
#   - This is better than approximate char/sec for comparing models.
#
# Examples:
#
#   From master, test both master gateway and node09 backend:
#     perl benchmark_vllm_token_rate_v022_qwen35b.pl \
#       --target=both \
#       --model=qwen3.6-27b-fp8 \
#       --api-key=YOUR_STUDENT_TOKEN \
#       --node09-url=http://node09:8000/v1
#
#   From master, test gateway only:
#     perl benchmark_vllm_token_rate_v022_qwen35b.pl \
#       --target=master \
#       --model=qwen3.6-27b-fp8 \
#       --api-key=YOUR_STUDENT_TOKEN
#
#   From node09, test backend directly:
#     perl benchmark_vllm_token_rate_v022_qwen35b.pl \
#       --target=node09 \
#       --node09-url=http://127.0.0.1:8000/v1 \
#       --model=qwen3.6-27b-fp8 \
#       --allow-no-api-key
# =============================================================================

my %OPT = (
    target                    => 'both',   # master | node09 | both | custom

    master_url                => 'http://127.0.0.1:9000/v1',
    node09_url                => 'http://node09:8000/v1',
    custom_url                => '',

    api_key                   => $ENV{LAB_VLLM_API_KEY} || $ENV{VLLM_API_KEY} || '',
    node09_api_key            => '',
    allow_no_api_key          => 0,

    model                     => 'qwen3.6-27b-fp8',

    prompt                    => 'Write a concise 300-word explanation of what vLLM does.',
    prompt_file               => '',
    system_prompt             => '',

    max_tokens                => 512,
    temperature               => '0.2',

    runs                      => 3,
    warmup                    => 1,
    retry                     => 1,
    retry_wait                => 3,
    timeout                   => 600,

    # Adds:
    #   chat_template_kwargs: { enable_thinking: false }
    # Usually not needed if your backend was already launched with:
    #   --default-chat-template-kwargs '{"enable_thinking": false}'
    request_disable_thinking  => 0,

    show_response             => 0,
    show_json                 => 0,
    csv                       => '',
);

parse_args(\%OPT, \@ARGV);

if ($OPT{prompt_file}) {
    $OPT{prompt} = read_file($OPT{prompt_file});
}

main();
exit 0;

# =============================================================================
# Main
# =============================================================================

sub main {
    validate_options();

    my @targets;

    if ($OPT{target} eq 'master') {
        push @targets, {
            label   => 'master-gateway',
            url     => normalize_url($OPT{master_url}),
            api_key => $OPT{api_key},
        };
    }
    elsif ($OPT{target} eq 'node09') {
        push @targets, {
            label   => 'node09-backend',
            url     => normalize_url($OPT{node09_url}),
            api_key => $OPT{node09_api_key},
        };
    }
    elsif ($OPT{target} eq 'both') {
        push @targets, {
            label   => 'master-gateway',
            url     => normalize_url($OPT{master_url}),
            api_key => $OPT{api_key},
        };
        push @targets, {
            label   => 'node09-backend',
            url     => normalize_url($OPT{node09_url}),
            api_key => $OPT{node09_api_key},
        };
    }
    elsif ($OPT{target} eq 'custom') {
        die "--custom-url is required when --target=custom\n" unless $OPT{custom_url};
        push @targets, {
            label   => 'custom',
            url     => normalize_url($OPT{custom_url}),
            api_key => $OPT{api_key},
        };
    }
    else {
        die "Invalid --target=$OPT{target}. Use master, node09, both, or custom.\n";
    }

    print_header();

    my @all_results;
    for my $t (@targets) {
        my @rows = benchmark_endpoint($t->{label}, $t->{url}, $t->{api_key});
        push @all_results, @rows;
    }

    if ($OPT{csv}) {
        write_csv($OPT{csv}, \@all_results);
        print "\nCSV written: $OPT{csv}\n";
    }
}

sub print_header {
    print "========================================\n";
    print "vLLM token-rate benchmark\n";
    print "========================================\n";
    print "Timestamp                 : " . strftime('%F %T', localtime()) . "\n";
    print "Target                    : $OPT{target}\n";
    print "Model                     : $OPT{model}\n";
    print "Runs                      : $OPT{runs}\n";
    print "Warmup                    : $OPT{warmup}\n";
    print "Max tokens                : $OPT{max_tokens}\n";
    print "Temperature               : $OPT{temperature}\n";
    print "Request disable thinking  : " . ($OPT{request_disable_thinking} ? 'yes' : 'no') . "\n";
    print "Prompt chars              : " . length($OPT{prompt}) . "\n";
    print "Master URL                : " . normalize_url($OPT{master_url}) . "\n";
    print "Node09 URL                : " . normalize_url($OPT{node09_url}) . "\n";
    print "\n";
}

# =============================================================================
# Benchmark
# =============================================================================

sub benchmark_endpoint {
    my ($label, $base_url, $api_key) = @_;

    print "========================================\n";
    print "Endpoint: $label\n";
    print "URL     : $base_url\n";
    print "API key : " . ($api_key ? 'enabled' : 'disabled') . "\n";
    print "========================================\n";

    if (!$api_key && !$OPT{allow_no_api_key} && $label ne 'node09-backend') {
        die "API key is required for $label. Use --api-key=TOKEN or --allow-no-api-key.\n";
    }

    check_models($label, $base_url, $api_key);

    my @results;

    for my $i (1 .. $OPT{warmup}) {
        print "[warmup $i/$OPT{warmup}] ";
        my $r = run_one_completion($label, $base_url, $api_key, 'warmup', $i);
        print_summary_line($r);
    }

    print "\n";

    for my $i (1 .. $OPT{runs}) {
        print "[run $i/$OPT{runs}] ";
        my $r = run_one_completion($label, $base_url, $api_key, 'run', $i);
        print_summary_line($r);
        push @results, $r;
    }

    print_endpoint_average($label, \@results);
    print "\n";

    return @results;
}

sub check_models {
    my ($label, $base_url, $api_key) = @_;

    my $url = "$base_url/models";
    my ($ok, $status, $body) = http_get($url, $api_key);

    if (!$ok) {
        print "FAIL: GET /models failed for $label, status=$status\n";
        print "$body\n" if defined $body;
        die "Endpoint model check failed\n";
    }

    my $data = eval { decode_json($body) };
    if ($@ || ref($data) ne 'HASH' || ref($data->{data}) ne 'ARRAY') {
        print "FAIL: invalid /models JSON from $label\n";
        print "$body\n";
        die "Endpoint model check failed\n";
    }

    my @ids = map { $_->{id} || '' } @{ $data->{data} };
    print "Available models: " . join(', ', @ids) . "\n";

    if (!grep { $_ eq $OPT{model} } @ids) {
        die "Model '$OPT{model}' not found on $label\n";
    }

    print "PASS: model '$OPT{model}' found on $label\n\n";
}

sub run_one_completion {
    my ($label, $base_url, $api_key, $phase, $idx) = @_;

    my $payload = build_payload();
    my $url = "$base_url/chat/completions";

    my ($ok, $status, $body, $elapsed) = http_post_json_retry($url, $api_key, $payload);

    my %r = (
        timestamp          => strftime('%F %T', localtime()),
        label              => $label,
        phase              => $phase,
        index              => $idx,
        model              => $OPT{model},
        http_status        => $status || '',
        ok                 => $ok ? 1 : 0,
        elapsed_sec        => $elapsed || 0,
        prompt_tokens      => 0,
        completion_tokens  => 0,
        total_tokens       => 0,
        tokens_per_sec     => 0,
        finish_reason      => '',
        content_chars      => 0,
        content_preview    => '',
        reasoning_present  => 0,
        error              => '',
    );

    if (!$ok) {
        $r{error} = defined($body) ? substr($body, 0, 500) : 'HTTP request failed';
        return \%r;
    }

    my $data = eval { decode_json($body) };
    if ($@ || ref($data) ne 'HASH') {
        $r{ok} = 0;
        $r{error} = "Invalid JSON response: " . substr($body || '', 0, 500);
        return \%r;
    }

    if (exists $data->{error}) {
        $r{ok} = 0;
        $r{error} = encode_json($data->{error});
        return \%r;
    }

    my $usage = $data->{usage} || {};
    $r{prompt_tokens}     = int($usage->{prompt_tokens} || 0);
    $r{completion_tokens} = int($usage->{completion_tokens} || 0);
    $r{total_tokens}      = int($usage->{total_tokens} || 0);

    if ($r{elapsed_sec} > 0 && $r{completion_tokens} > 0) {
        $r{tokens_per_sec} = $r{completion_tokens} / $r{elapsed_sec};
    }

    if (ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}}) {
        my $choice = $data->{choices}[0];
        $r{finish_reason} = $choice->{finish_reason} || '';

        my $msg = $choice->{message} || {};
        if (ref($msg) eq 'HASH') {
            my $content = $msg->{content} // '';
            my $reasoning = $msg->{reasoning};

            $r{content_chars} = length($content);
            $r{content_preview} = printable(substr($content, 0, 120));
            $r{reasoning_present} = defined($reasoning) && $reasoning ne '' ? 1 : 0;

            if ($OPT{show_response}) {
                print "\n--- response content preview ---\n";
                print $content . "\n";
                print "--- end response content ---\n";
            }
        }
    }

    if ($OPT{show_json}) {
        print "\n--- raw JSON ---\n$body\n--- end raw JSON ---\n";
    }

    return \%r;
}

sub build_payload {
    my @messages;

    if ($OPT{system_prompt} ne '') {
        push @messages, {
            role    => 'system',
            content => $OPT{system_prompt},
        };
    }

    push @messages, {
        role    => 'user',
        content => $OPT{prompt},
    };

    my %payload = (
        model       => $OPT{model},
        messages    => \@messages,
        max_tokens  => int($OPT{max_tokens}),
        temperature => 0 + $OPT{temperature},
    );

    if ($OPT{request_disable_thinking}) {
        $payload{chat_template_kwargs} = {
            enable_thinking => JSON::PP::false,
        };
    }

    return \%payload;
}

sub print_summary_line {
    my ($r) = @_;

    if (!$r->{ok}) {
        print "FAIL status=$r->{http_status} elapsed=" . fmt($r->{elapsed_sec}) . "s error=$r->{error}\n";
        return;
    }

    print "status=$r->{http_status} "
        . "time=" . fmt($r->{elapsed_sec}) . "s "
        . "prompt=$r->{prompt_tokens} "
        . "completion=$r->{completion_tokens} "
        . "tok_s=" . fmt($r->{tokens_per_sec}) . " "
        . "finish=$r->{finish_reason} "
        . "reasoning=" . ($r->{reasoning_present} ? 'yes' : 'no') . "\n";
}

sub print_endpoint_average {
    my ($label, $results) = @_;

    my @ok = grep { $_->{ok} && $_->{completion_tokens} > 0 && $_->{elapsed_sec} > 0 } @$results;

    if (!@ok) {
        print "\n--- $label average ---\n";
        print "No successful benchmark runs.\n";
        return;
    }

    my $n = scalar @ok;
    my $sum_elapsed = 0;
    my $sum_completion = 0;
    my $sum_prompt = 0;
    my $sum_tok_s = 0;

    for my $r (@ok) {
        $sum_elapsed += $r->{elapsed_sec};
        $sum_completion += $r->{completion_tokens};
        $sum_prompt += $r->{prompt_tokens};
        $sum_tok_s += $r->{tokens_per_sec};
    }

    my $aggregate_tok_s = $sum_completion / $sum_elapsed;
    my $mean_tok_s = $sum_tok_s / $n;

    print "\n--- $label average over $n run(s) ---\n";
    print "avg_elapsed_sec          = " . fmt($sum_elapsed / $n) . "\n";
    print "avg_prompt_tokens        = " . fmt($sum_prompt / $n) . "\n";
    print "avg_completion_tokens    = " . fmt($sum_completion / $n) . "\n";
    print "mean_tokens_per_sec      = " . fmt($mean_tok_s) . "\n";
    print "aggregate_tokens_per_sec = " . fmt($aggregate_tok_s) . "\n";
}

# =============================================================================
# HTTP
# =============================================================================

sub http_get {
    my ($url, $api_key) = @_;

    my $http = HTTP::Tiny->new(
        timeout => $OPT{timeout},
        verify_SSL => 0,
        default_headers => build_headers($api_key),
    );

    my $res = $http->get($url);
    return ($res->{success} ? 1 : 0, $res->{status}, $res->{content});
}

sub http_post_json_retry {
    my ($url, $api_key, $payload) = @_;

    my $last_ok = 0;
    my $last_status = '';
    my $last_body = '';
    my $last_elapsed = 0;

    for my $try (1 .. $OPT{retry}) {
        my ($ok, $status, $body, $elapsed) = http_post_json($url, $api_key, $payload);
        return ($ok, $status, $body, $elapsed) if $ok;

        $last_ok = $ok;
        $last_status = $status;
        $last_body = $body;
        $last_elapsed = $elapsed;

        if ($try < $OPT{retry}) {
            print "retrying after failure status=$status ... ";
            sleep $OPT{retry_wait};
        }
    }

    return ($last_ok, $last_status, $last_body, $last_elapsed);
}

sub http_post_json {
    my ($url, $api_key, $payload) = @_;

    my $http = HTTP::Tiny->new(
        timeout => $OPT{timeout},
        verify_SSL => 0,
    );

    my $headers = build_headers($api_key);
    $headers->{'Content-Type'} = 'application/json';

    my $body = encode_json($payload);

    my $start = time();
    my $res = $http->post(
        $url,
        {
            content => $body,
            headers => $headers,
        }
    );
    my $elapsed = time() - $start;

    return ($res->{success} ? 1 : 0, $res->{status}, $res->{content}, $elapsed);
}

sub build_headers {
    my ($api_key) = @_;
    my %headers = (
        'Accept' => 'application/json',
    );

    if (defined $api_key && $api_key ne '') {
        $headers{'Authorization'} = "Bearer $api_key";
    }

    return \%headers;
}

# =============================================================================
# CSV
# =============================================================================

sub write_csv {
    my ($file, $rows) = @_;

    open my $fh, '>', $file or die "Cannot write CSV $file: $!\n";

    my @cols = qw(
        timestamp
        label
        phase
        index
        model
        http_status
        ok
        elapsed_sec
        prompt_tokens
        completion_tokens
        total_tokens
        tokens_per_sec
        finish_reason
        content_chars
        reasoning_present
        error
    );

    print {$fh} join(',', @cols) . "\n";

    for my $r (@$rows) {
        my @vals = map { csv_escape($r->{$_}) } @cols;
        print {$fh} join(',', @vals) . "\n";
    }

    close $fh;
}

sub csv_escape {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/"/""/g;
    return qq{"$v"};
}

# =============================================================================
# Utilities
# =============================================================================

sub validate_options {
    die "--model is required\n" unless $OPT{model};

    for my $k (qw(runs warmup retry retry_wait timeout max_tokens)) {
        die "Invalid --$k=$OPT{$k}\n" unless defined($OPT{$k}) && $OPT{$k} =~ /^\d+$/;
    }

    die "Invalid --temperature=$OPT{temperature}\n"
        unless defined($OPT{temperature}) && $OPT{temperature} =~ /^\d+(?:\.\d+)?$/;

    if ($OPT{target} eq 'master' || $OPT{target} eq 'both' || $OPT{target} eq 'custom') {
        if (!$OPT{api_key} && !$OPT{allow_no_api_key}) {
            die "--api-key is required for master/custom target unless --allow-no-api-key is used.\n";
        }
    }
}

sub normalize_url {
    my ($u) = @_;
    $u =~ s{/$}{};
    return $u;
}

sub read_file {
    my ($file) = @_;
    local $/;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

sub printable {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\r/\\r/g;
    $s =~ s/\n/\\n/g;
    return $s;
}

sub fmt {
    my ($x) = @_;
    $x = 0 unless defined $x && $x ne '';
    return sprintf('%.3f', $x);
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
        elsif ($arg eq '--allow-no-api-key') {
            $opt->{allow_no_api_key} = 1;
        }
        elsif ($arg eq '--request-disable-thinking') {
            $opt->{request_disable_thinking} = 1;
        }
        elsif ($arg eq '--show-response') {
            $opt->{show_response} = 1;
        }
        elsif ($arg eq '--show-json') {
            $opt->{show_json} = 1;
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
  perl benchmark_vllm_token_rate_v022_qwen35b.pl [options]

Common options:
  --target=master|node09|both|custom
      Default: both

  --master-url=http://127.0.0.1:9000/v1
      Default: http://127.0.0.1:9000/v1

  --node09-url=http://node09:8000/v1
      Default: http://node09:8000/v1
      If running on node09 itself, use:
      --node09-url=http://127.0.0.1:8000/v1

  --custom-url=http://HOST:PORT/v1
      Required when --target=custom.

  --api-key=TOKEN
      Required for master gateway unless --allow-no-api-key is used.
      You may also set LAB_VLLM_API_KEY or VLLM_API_KEY.

  --node09-api-key=TOKEN
      Optional. Backend direct usually has no API key in your current setup.

  --allow-no-api-key
      Allows testing endpoints without Authorization header.

  --model=MODEL
      Default: qwen3.6-27b-fp8

  --runs=N
      Default: 3

  --warmup=N
      Default: 1

  --max-tokens=N
      Default: 512

  --temperature=FLOAT
      Default: 0.2

  --timeout=N
      Default: 600

  --retry=N
      Default: 1

  --retry-wait=N
      Default: 3

Prompt options:
  --prompt="..."
  --prompt-file=/path/to/prompt.txt
  --system-prompt="..."

Qwen thinking options:
  --request-disable-thinking
      Adds chat_template_kwargs.enable_thinking=false to each request.
      Not needed if your vLLM server was launched with:
      --default-chat-template-kwargs '{"enable_thinking": false}'

Output options:
  --show-response
  --show-json
  --csv=/path/to/results.csv

Examples:

  From master, test both master gateway and node09 backend:
    perl benchmark_vllm_token_rate_v022_qwen35b.pl \
      --target=both \
      --model=qwen3.6-27b-fp8 \
      --api-key=YOUR_STUDENT_TOKEN \
      --node09-url=http://node09:8000/v1 \
      --runs=3 \
      --warmup=1

  From master, test gateway only:
    perl benchmark_vllm_token_rate_v022_qwen35b.pl \
      --target=master \
      --model=qwen3.6-27b-fp8 \
      --api-key=YOUR_STUDENT_TOKEN

  From node09, test backend directly:
    perl benchmark_vllm_token_rate_v022_qwen35b.pl \
      --target=node09 \
      --node09-url=http://127.0.0.1:8000/v1 \
      --model=qwen3.6-27b-fp8 \
      --allow-no-api-key

  Save CSV:
    perl benchmark_vllm_token_rate_v022_qwen35b.pl \
      --target=both \
      --model=qwen3.6-27b-fp8 \
      --api-key=YOUR_STUDENT_TOKEN \
      --csv=/tmp/vllm_benchmark.csv
USAGE
}