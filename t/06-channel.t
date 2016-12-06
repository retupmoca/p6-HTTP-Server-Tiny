use v6;

use Test;
use lib 't/lib';
use Test::TCP;

use HTTP::Server::Tiny;
use HTTP::Tinyish;

plan 1;

my $port = 15555;

my $server = HTTP::Server::Tiny.new(host => '127.0.0.1', port => $port);

my $channel = Channel.new;

start {
    for 1..100 {
                $channel.send($_.Str.encode('utf-8'));
    }
    $channel.close;
};

Thread.start({
    $server.run(sub ($env) {
        return 200, ['Content-Type' => 'text/plain'], $channel
    });
}, :app_lifetime);

wait_port($port);
my $resp = HTTP::Tinyish.new.post("http://127.0.0.1:$port/",
   headers => { 
        'content-type' => 'application/x-www-form-urlencoded'
    },
    content => 'foo=bar');
is($resp<content>, "123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100");

