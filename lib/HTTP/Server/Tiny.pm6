use v6;
unit class HTTP::Server::Tiny:ver<0.0.1>;

use HTTP::Parser; # parse-http-request
use IO::Blob;
use HTTP::Status;

my Buf $CRLF = Buf.new(0x0d, 0x0a);

my constant DEBUGGING = %*ENV<HST_DEBUG>.Bool;

my class HandleSupplier {
    has IO::Handle $.handle;
    has $.supplier;

    method new($handle) {
        my $supplier = Supplier.new;
        my $self = self.bless(supplier => $supplier, handle => $handle);
        my $supply = $supplier.Supply;
        $supply.tap(-> $v { $self.handle.say($v) });
        return $self;
    }
}

my class TempFile {
    has $.filename;
    has $.fh;

    method new() {
        for 1..10 {
            my $filename = $*TMPDIR.child("p6-httpd" ~ nonce());
            my $fh = open $filename, :rw, :exclusive;
            $fh.path.chmod(0o600);
            debug "filename: $filename: {$fh.opened}";
            return self.bless(filename => $filename, fh => $fh);
            CATCH { default { debug($_) if DEBUGGING; next } }
        }
        die "cannot create temporary file";
    }

    my sub nonce () { return (".{$*PID}." ~ flat('a'..'z', 'A'..'Z', 0..9, '_').roll(10).join) }

    method write(Blob $b) {
        debug "write to $.filename";
        $.fh.write($b)
    }

    method read(Int(Cool:D) $bytes) {
        $.fh.read: $bytes
    }

    method seek(Int:D $offset, SeekType:D $whence) {
        $.fh.seek($offset, $whence);
    }

    method tell() {
        $.fh.tell();
    }

    method slurp-rest(:$bin!) {
        $.fh.slurp-rest: bin => $bin
    }

    method close() {
        debug 'closing temp file';
        try unlink $.filename;
        try close $.fh;
    }

    method DESTROY {
        debug 'destroy tempfile';
        self.close
    }

    method Supply() {
        return $.fh.Supply;
    }
}

my class HTTP::Server::Tiny::Handler {
    has $.use-keepalive is required;
    has $.host is required;
    has $.port is required;
    has buf8 $.buf .= new;
    has Bool $!header-parsed = False;
    has %!env;
    has $!input;
    has $!chunked;
    has $!content-length;
    has $.conn is required;
    has $!wrote-body-size = 0;
    has $.sent-response = False;
    has Callable $.app is required;
    has Str $!protocol = "HTTP/1.0";
    has Str $.server-software is required;
    has int $.request-count = 1;
    has int $.max-keepalive-reqs is required;
    has Bool $!connection-upgrade = False;

    method handle($got) {
        $!buf ~= $got;

        unless $!header-parsed {
            self!parse-header();
        }
        if $!header-parsed {
            self!parse-body();
        }
    }

    method next-request() {
        self.close();

        my $use-keepalive = $.request-count < $.max-keepalive-reqs
            && $!buf.defined && $!buf.elems > 0;
        my $handler = HTTP::Server::Tiny::Handler.new(
            use-keepalive      => $!max-keepalive-reqs < $!request-count,
            request-count      => $!request-count+1,
            max-keepalive-reqs => $!max-keepalive-reqs,
            server-software    => $!server-software,
            app                => $!app,
            conn               => $!conn,
            host               => $!host,
            port               => $!port,
        );
        if $!buf.elems > 0 {
            $handler.handle($!buf);
        }
        $handler;
    }

    method !parse-header() {
        debug 'parsing http request';
        my ($header_len, $env) = parse-http-request($!buf);
        %!env = %$env;
        debug("http parsing status: $header_len");
        if $header_len > 0 {
            $!buf = $!buf.subbuf($header_len);
            %!env<SERVER_NAME> = $.host;
            %!env<SERVER_PORT> = $.port;
            %!env<SCRIPT_NAME> = '';
            %!env<p6w.version> = Version.new('v0.7.Draft');
            %!env<p6w.multithread> = True;
            %!env<p6w.multiprocess> = False;
            %!env<p6w.run-once> = False;
            %!env<p6w.errors> = HandleSupplier.new($*ERR).supplier;
            %!env<p6w.url-scheme> = 'http';
            %!env<p6wx.io>     = $!conn; # for websocket support
            %!env<p6w.protocol.support> = set('request-response', 'psgi');
            %!env<p6w.protocol.enabled> = SetHash('request-response', 'psgi');

            # TODO: REMOTE_ADDR
            # TODO: REMOTE_PORT

            my $content-length = %!env<CONTENT_LENGTH>;
            if $content-length.defined {
                $!content-length = $content-length.Int;
            }

            $!protocol = %!env<SERVER_PROTOCOL>;
            if $!use-keepalive {
                if $!protocol eq 'HTTP/1.1' {
                    if my $c = %!env<HTTP_CONNECTION> {
                        if $c ~~ m:i/^\s*close\s*/ {
                            $!use-keepalive = False;
                        }
                    }
                } else {
                    if my $c = %!env<HTTP_CONNECTION> {
                        unless $c ~~ m:i/^\s*keep\-alive\s*/ {
                            $!use-keepalive = False;
                        }
                    } else {
                        $!use-keepalive = False;
                    }
                }
            }

            debug "content-length: {$!content-length.perl}";

            $!chunked = %!env<HTTP_TRANSFER_ENCODING>
                ?? %!env<HTTP_TRANSFER_ENCODING>.lc eq 'chunked'
                !! False;

            $!header-parsed = True;
        } elsif $header_len == -1 { # incomplete header
            debug 'incomplete header' unless DEBUGGING;
        } elsif $header_len == -2 { # invalid request
            self!send-response(400, [], ['Bad request']);
        } else {
            die "should not reach here";
        }
    }

    method !parse-body() {
        if $!content-length.defined {
            $!input //= self!create-temp-buffer($!content-length);

            debug "got {$!buf.elems} bytes";
            my $write-bytes = $!buf.elems min $!content-length;
            if $write-bytes {
                $!input.write($!buf.subbuf(0, $write-bytes)); # XXX blocking
                $!wrote-body-size += $write-bytes;
                $!buf = $!buf.subbuf($write-bytes);
                debug "remains { $!content-length - $!wrote-body-size }";
            }

            if $!wrote-body-size == $!content-length {
                debug "got all content body";
                return self!run-app();
            }
        } elsif $!chunked {
            $!input //= self!create-temp-buffer(Nil);

            my $wrote = 0;
            PROCESS_CHUNK: loop {
                for 0..^$!buf.bytes-1 -> $end_pos {
                    if $!buf[$end_pos]==0x0d && $!buf[$end_pos+1]==0x0a {
                        debug 'found chunk marker';
                        my $size = $!buf.subbuf(0, $end_pos);
                        my $chunk_len = :16($size.decode('ascii'));
                        debug "got chunk {$end_pos+2} + $chunk_len {$!buf.elems}";
                        if $chunk_len == 0 {
                            debug "end chunk";
                            debug "wrote $wrote bytes by chunked";
                            %!env<CONTENT_LENGTH> = $wrote.Str;
                            return self!run-app();
                        }
                        if $end_pos+2+$chunk_len <= $!buf.elems {
                            debug 'writing temp file';
                            $!input.write($!buf.subbuf($end_pos+2, $chunk_len));
                            $wrote += $chunk_len;
                            $!buf = $!buf.subbuf($end_pos+2 + $chunk_len);
                            next PROCESS_CHUNK;
                        }
                    }
                }
                return; # partial
            }
        } else {
            $!input //= IO::Blob.new;

            if $!buf.decode('ascii') ~~ /^[GET|HEAD]/ { # pipeline
                $!use-keepalive = True; # force keep-alive
            } else {
                $!buf = buf8.new; # clear buffer
            }
            return self!run-app();
        }

        if %!env<HTTP_EXPECT> {
            if %!env<HTTP_EXPECT> eq '100-continue' {
                await $.conn.print("HTTP/1.1 100 Continue\r\n\r\n");
            } else {
                debug "Expectation failed" if DEBUGGING;
                my $body = 'Expectation Failed';
                self!send-response(
                    417, [
                        'Content-Type' => 'text/plain',
                        'Connection' => 'close',
                        'Content-length' => $body.elems],
                    [$body]);
                $.conn.close;
            }
        }
    }

    method !run-app() {
        $!input.seek(0,SeekFromBeginning); # rewind;
        %!env<p6w.input> = $!input.Supply;

        my ($status, $headers, $body) = sub {
            CATCH {
                default {
                    error($_);
                    return 500, [], ['Internal Server Error!'];
                }
            };
            my $result = $!app.(%!env);
            if $result ~~ Promise {
                return $result.result;
            }
            return $result;
        }();
        debug "ran app: $status" if DEBUGGING;
        self!send-response($status, $headers, $body);
    }

    method !send-response($status, $headers, $body) {

        CATCH {
            when /"broken pipe"/ {
                debug("client close sending response");
                return;
            }
        }
        debug "sending response $status";

        my $resp_string = "$!protocol $status {get_http_status_msg $status}\r\n";
        my %send_headers;
        for @($headers) {
            if .key ~~ /<[\r\n]>/ {
                die "header split";
            }

            my $lck = .key.lc;
            if ($lck eq 'connection') {
                if .value.lc eq 'upgrade' {
                    $!connection-upgrade = True;
                    $resp_string ~= "{.key}: {.value}\r\n";
                } else {
                    if $!use-keepalive && .value.lc ne 'keep-alive' {
                        $!use-keepalive = False;
                    }
                }
            } else {
                $resp_string ~= "{.key}: {.value}\r\n";
            }

            %send_headers{$lck} = .value;
        }
        unless %send_headers<server> {
            $resp_string ~= "server: $.server-software\r\n";
        }
        unless %send_headers<date> {
            $resp_string ~= "date: {http-date}\r\n";
        }

        # try to set content-length when keepalive can be used, or disable it
        my $use-chunked = False;
        if $!protocol eq 'HTTP/1.0' {
            if $!use-keepalive {
                # Plack::Util::content_length
                my sub content-length($body) {
                    return Nil unless defined $body;
                    if $body ~~ Array {
                        my $cl = 0;
                        for @($body) {
                            $cl += ($_ ~~ Str ?? .encode() !! $_).bytes;
                        }
                        return $cl;
                    } elsif $body ~~ IO::Handle {
                        return $body.s;
                    }
                }

                if %send_headers<content-length>.defined && %send_headers<transfer-encoding>.defined {
                    # ok
                } elsif !status-with-no-entity-body($status) && (my $cl = content-length($body)) {
                    debug "calcurated content-length: $cl" if DEBUGGING;
                    $resp_string ~= "content-length: $cl\x0d\x0a";
                } else {
                    $!use-keepalive = False;
                }

                $resp_string ~= "Connection: keep-alive\x0d\x0a" if $!use-keepalive;
                $resp_string ~= "Connection: close\x0d\x0a" unless $!use-keepalive; # fmm
            }
        } elsif $!protocol eq 'HTTP/1.1' {
            if %send_headers<content-length>.defined || %send_headers<transfer-encoding>.defined {
                # ok
            } elsif !status-with-no-entity-body(+$status) {
                $resp_string ~= "Transfer-Encoding: chunked\x0d\x0a";
                $use-chunked = True;
            }
            if !$!use-keepalive && !$!connection-upgrade {
                $resp_string ~= "Connection: close\x0d\x0a";
            }
        }
        $resp_string ~= "\r\n";

        # TODO combine response header and small request body

        my $resp = $resp_string.encode('ascii');
        await $.conn.write($resp);

        debug "sent header";

        for scan-psgi-body($body) -> Blob $got {
            next if $got.bytes == 0;

            if $use-chunked {
                my $buf = sprintf("%X", $got.bytes).encode('ascii') ~ $CRLF ~ $got ~ $CRLF;
                await $.conn.write($buf);
            } else {
                await $.conn.write($got);
            }
        }
        if $use-chunked {
            debug "send end mark";
            await $.conn.write("0".encode('ascii') ~ $CRLF ~ $CRLF);
        }

        debug "sent body" if DEBUGGING;

        $!sent-response = True;
    }

    method !create-temp-buffer($len) {
        if $len.defined && $len < 64_000 {
            debug('blob') if DEBUGGING;
            IO::Blob.new
        } else {
            debug('tempfile') if DEBUGGING;
            TempFile.new;
        }
    }

    method DESTROY() {
        debug "Destroying handler";
    }
}

has $.port = 80;
has $.host = '127.0.0.1';
has Str $.server-software = "HTTP::Server::Tiny";
has $.max-keepalive-reqs = 1;

my sub info($message) {
    say "[INFO] [{$*PID}] [{$*THREAD.id}] $message";
}


my sub debug($message) {
    say "[DEBUG] [{$*PID}] [{$*THREAD.id}] $message" if DEBUGGING;
}

my multi sub error(Exception $err) {
    say "[ERROR] [{$*PID}] [{$*THREAD.id}] $err {$err.backtrace}";
}

my multi sub error(Str $err) {
    say "[ERROR] [{$*PID}] [{$*THREAD.id}] $err";
}

# Plack::Util::content_length
my sub content-length($body) {
    return Nil unless defined $body;
    if $body ~~ Array {
        my $cl = 0;
        for @($body) {
            given $_ {
                when Str {
                    $cl += .encode().bytes;
                }
                when Blob {
                    $cl += .bytes;
                }
                default {
                    die "unsupported response type: {.gist}";
                }
            }
        }
        return $cl;
    } elsif $body ~~ IO::Handle {
        return $body.s;
    }
}

my sub status-with-no-entity-body(int $status) {
    return $status < 200 || $status == 204 || $status == 304;
}

sub take-blobified($elem) {
    if $elem ~~ Blob {
        take $elem;
    } elsif $elem ~~ Mu {
        take $elem.Str.encode;
    } else {
        die "response must be Array[Blob]. But {$elem.perl}";
    }
}

my sub scan-psgi-body($body) {
    gather {
        if $body ~~ Array {
            for @($body) -> $elem {
                take-blobified $elem;
            }
        } elsif $body ~~ IO::Handle {
            until $body.eof {
                take $body.read(1024);
            }
            $body.close;
        } elsif $body ~~ Channel {
            while my $got = $body.receive {
                take-blobified $got;
            }
            CATCH { when X::Channel::ReceiveOnClosed { debug('closed channel'); } }
        } elsif $body ~~ Supply {
            my $ch = $body.Channel;
            while my $got = $ch.receive {
                take-blobified $got;
            }
            CATCH { when X::Channel::ReceiveOnClosed { debug('closed channel'); } }
        } else {
            die "3rd element of response object must be instance of Array or IO::Handle or Channel";
        }
    }
}


method run(HTTP::Server::Tiny:D: Callable $app, Promise :$control-promise = Promise.new) {
    # moarvm doesn't handle SIGPIPE correctly. Without this,
    # perl6 exit without any message.
    # -- tokuhirom@20151003
    signal(SIGPIPE).tap({ debug("Got SIGPIPE") }) unless $*DISTRO.is-win;

    # TODO: I want to use IO::Socket::Async#port method to use port 0.
    say "http server is ready: http://$.host:$.port/ (pid:$*PID, keepalive: $.max-keepalive-reqs)";

    react {
        whenever IO::Socket::Async.listen($.host, $.port) -> $conn {
            self!handler($conn, $app);
            QUIT {
                error($_);
                done;
            }
        }
        whenever $control-promise {
            debug("Exiting on control promise");
            done;
        }
    }
}

method !handler(IO::Socket::Async $conn, Callable $app) {
    debug("new request");

    CATCH {
        when /^"broken pipe"$/ {
            error("broken pipe");
            return;
        }
        default {
            error($_);
            return;
        }
    }

    my $bs = $conn.Supply(:bin);
    my $pipelined_buf;
    my $handler = HTTP::Server::Tiny::Handler.new(
        use-keepalive      => $.max-keepalive-reqs != 1,
        max-keepalive-reqs => $.max-keepalive-reqs,
        server-software    => $.server-software,
        conn               => $conn,
        app                => $app,
        host               => $.host,
        port               => $.port,
    );
    $bs.tap(
        -> $got {
            debug "got chunk";

            $handler.handle($got);
            if $handler.sent-response {
                debug 'sent response' if DEBUGGING;
                if $handler.use-keepalive {
                    debug "use keepalive for next request";
                    $handler = $handler.next-request;
                } else {
                    debug 'closing connection' if DEBUGGING;
                    try $conn.close;
                    debug 'closed connection' if DEBUGGING;
                }
            }
            CATCH { default { error($_); try $conn.close; } };
        },
        quit => { debug("QUIT") },
        done => { debug "DONE" },
        closing => { debug("CLOSING") },
    );
}

my @WDAY = <Sun Mon Tue Wed Thu Fri Sat Sun>;
my @MON = <Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec>;
my sub http-date() {
    my $dt = DateTime.now;
    return sprintf("%s, %02d-%s-%04d %02d:%02d:%02d GMT",
            @WDAY[$dt.day-of-week], $dt.day-of-month, @MON[$dt.month-1], $dt.year,
            $dt.hour, $dt.minute, $dt.second);
}

=begin pod

=head1 NAME

HTTP::Server::Tiny - a simple HTTP server for Perl6

=head1 SYNOPSIS


    use HTTP::Server::Tiny;

    my $port = 8080;

    # Only listen for connections from the local host
    # if you want this to be accessible from another
    # host then change this to '0.0.0.0'
    my $host = '127.0.0.1';

    HTTP::Server::Tiny.new(:$host , :$port).run(sub ($env) {
        my $channel = Channel.new;
        start {
            for 1..100 {
                $channel.send(($_ ~ "\n").Str.encode('utf-8'));
            }
            $channel.close;
        };
        return 200, ['Content-Type' => 'text/plain'], $channel
    });


=head1 DESCRIPTION

HTTP::Server::Tiny is a standalone HTTP/1.1 web server for perl6.

=head1 METHODS

=item C<HTTP::Server::Tiny.new($host, $port)>

Create new instance.

=item C<$server.run(Callable $app, Promise :$control-promise)>

Run http server with P6W app. The named parameter C<control-promise>
if provided, can be I<kept> to quit the server loop, which may be useful
if the server is run asynchronously to the main thread of execution in
an application.

If the optional named parameter C<control-promise> is provided with a
C<Promise> then the server loop will be quit when the promise is kept.

=head1 VERSIONING RULE

This module respects L<Semantic versioning|http://semver.org/>

=head1 TODO

=item Support timeout

=head1 COPYRIGHT AND LICENSE

Copyright 2015, 2016 Tokuhiro Matsuno <tokuhirom@gmail.com>

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
