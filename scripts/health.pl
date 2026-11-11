# Health responder for the RunPod load balancer. It runs next to llama-server.
#
#   204 = the worker starts (llama-server loads the model, or the warm-up runs)
#   200 = the worker is ready
#
# The load balancer polls a worker that replies 204 every ~1.25 s. Thus it
# sends traffic quickly after the worker becomes ready.
#
# A child process waits for llama-server, then sends one small request. The
# first request on a new llama-server is ~1 s slower (CUDA graph setup). The
# warm-up pays that cost before the first real request.
#
# The stock llama.cpp image contains perl-base only. Use core modules only.
use strict;
use IO::Socket::INET;
$| = 1;
# A peer can close its connection before the reply. Do not stop on that.
$SIG{PIPE} = 'IGNORE';

my $port = $ENV{PORT_HEALTH} || 8081;
my $up   = $ENV{LLAMA_ARG_PORT} || 80;
my $flag = "/tmp/warm.$$";

# One HTTP/1.0 request to llama-server. Returns the status code, or 0.
sub upstream {
  my ($method, $path, $body, $timeout) = @_;
  my $status = 0;
  eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm($timeout);
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $up, Timeout => 2) or die "connect\n";
    print $c "$method $path HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
    my $line = <$c> // '';
    $status = $1 if $line =~ m{^HTTP/\S+ (\d+)};
    1 while defined(<$c>);  # read the full reply, so that the request completes
    close $c;
  };
  alarm 0;
  return $status;
}

sub touch { if (open(my $f, '>', $flag)) { close $f } }

my $server = IO::Socket::INET->new(LocalAddr => '0.0.0.0', LocalPort => $port, Listen => 128, ReuseAddr => 1)
  or die "health: cannot listen on $port: $!\n";

# Warm-up child.
my $pid = fork();
if (defined $pid && $pid == 0) {
  close $server;
  sleep 1 while upstream('GET', '/health', '', 3) != 200;
  my $body = '{"model":"warmup","max_tokens":24,"temperature":0,"chat_template_kwargs":{"enable_thinking":false},'
           . '"messages":[{"role":"user","content":"Write the numbers from one to ten in words."}]}';
  my $status = upstream('POST', '/v1/chat/completions', $body, 60);
  print "health: warm-up done (status $status)\n";
  touch();
  exit 0;
}
$SIG{CHLD} = 'IGNORE';
# If fork fails, there is no warm-up. Do not block the worker.
touch() if !defined $pid;

my $last = '';
while (1) {
  my $c = $server->accept or next;
  eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 3;
    while (defined(my $h = <$c>)) { last if $h =~ /^\r?$/ }
    alarm 0;
  };
  alarm 0;
  my $code = (-e $flag && upstream('GET', '/health', '', 3) == 200) ? '200 OK' : '204 No Content';
  print $c "HTTP/1.1 $code\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  close $c;
  if ($code ne $last) { print "health: $code\n"; $last = $code; }
}
