#!/usr/bin/perl

# (C) 2025 Web Server LLC

# Tests for http3 'status_zone' directive.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;
use Test::Nginx::Stream qw/stream/;
use Test::Utils qw/get_json/;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/http http_api http_ssl http_v3 map socket_ssl_sni/)
	->has(qw/sni/)
	->has_daemon('openssl')->plan(1983)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen %%PORT_8080%%;

        location /status/ {
            api /status/;
        }
    }

    ssl_certificate rsa.crt;
    ssl_certificate_key rsa.key;

    server {
        listen %%PORT_8081_UDP%% quic;

        status_zone $uri zone=uri;

        location / {
            status_zone $uri zone=uri;
            return 200;
        }
    }

    server {
        listen %%PORT_8082_UDP%% quic;

        status_zone $uri zone=uri;

        location / {
            status_zone $uri zone=uri:15;
            return 200;
        }
    }

    server {
        listen %%PORT_8083_UDP%% quic;

        status_zone $uri zone=uri:15;

        location / {
            status_zone $uri zone=uri:15;
            return 200;
        }
    }

    server {
        listen %%PORT_8084_UDP%% quic;
        server_name *.a.example.com;

        status_zone $host zone=a_host:6;

        location / {
            status_zone $host zone=a_host:5;
            return 200;
        }
    }

    server {
        listen %%PORT_8084_UDP%% quic;
        server_name *.b.example.com;

        status_zone $host zone=b_host:5;

        location / {
            status_zone $host zone=b_host:5;
            return 200;
        }
    }

    server {
        listen %%PORT_8085_UDP%% quic;

        status_zone single;

        location / {
            status_zone single;
            return 200;
        }
    }

    server {
        listen %%PORT_8086_UDP%% quic;

        status_zone single;

        location / {
            status_zone single;
            return 200;
        }
    }

    server {
        listen %%PORT_8087_UDP%% quic;

        server_name *.sni.a.example.com;

        status_zone $ssl_server_name zone=sni:10;

        ssl_protocols TLSv1.3;

        location / {
            status_zone $ssl_server_name zone=sni:10;
            return 200;
        }
    }

    server {
        listen %%PORT_8088_UDP%% quic;

        server_name *.sni.b.example.com;

        status_zone $ssl_server_name zone=sni;

        ssl_protocols TLSv1.3;

        location / {
            status_zone $ssl_server_name zone=sni;
            return 200;
        }
    }

    server {
        listen %%PORT_8093_UDP%% quic;
        server_name *.example.com;

        status_zone $host zone=ssl_host:4;

        location / {
            status_zone off;
            return 200;
        }
    }

    server {
        listen %%PORT_8095_UDP%% quic;
        server_name *.example.com;

        status_zone $host zone=hosts:5;

        location / {
            status_zone $uri zone=uris:10;
            return 200;
        }

        location /loc1 {
            status_zone loc1;
            return 200;
        }

        location /loc2 {
            status_zone loc2;
            return 200;
        }
    }

    server {
        listen %%PORT_8096_UDP%% quic;

        location / {
            status_zone $uri zone=locations:10;
            return 200;
        }
    }

    server {
        server_name a.com;
        listen %%PORT_8097_UDP%% quic;
        status_zone a_sni_host;

        location / {
            return 200;
        }
    }

    server {
        server_name b.com;
        listen %%PORT_8097_UDP%% quic;
        status_zone b_sni_host;

        location / {
            return 200;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $tdir = $t->testdir();

system("openssl req -x509 -new -config $tdir/openssl.conf -subj /CN=rsa/ "
	. "-newkey rsa:2048 -keyout $tdir/rsa.key -out $tdir/rsa.crt "
	. "2>/dev/null") == 0
	or die "Can't create RSA certificate$!\n";

system("openssl ecparam -name secp384r1 -genkey -out $tdir/ecdsa.key "
	. "2>/dev/null") == 0
	or die "Can't create ECDSA key$!\n";

system("openssl req -new -config $tdir/openssl.conf "
	. "-subj /CN=ecdsa/ -key $tdir/ecdsa.key -x509 -nodes "
	. "-days 365 -out $tdir/ecdsa.crt 2>/dev/null") == 0
	or die "Can't create ECDSA certificate: $!\n";

$t->run();

my $a = 'a.example.com';
my $b = 'b.example.com';

###############################################################################

test_uri_zone();
test_locations_zone();
test_host_zone();
test_host_uri_zone();
test_single_zone();
test_sni_zone();
test_sni_host_zone();

# Check all previous states
check_uri_zone();
check_locations_zone();
check_host_zone();
check_host_uri_zone();
check_single_zone();
check_sni_zone();
check_sni_host_zone();

###############################################################################

sub check_stats {
	my ($j, $count) = @_;

	my $response_code = (exists $j->{responses}{200})
		? ($j->{responses}{200} == $count)
		: 1;

	return (
		ok($j->{requests}{total} == $count, 'check requests total') and
		ok($j->{requests}{discarded} == 0, 'check requests discarded') and
		ok($j->{data}{received} >= 0, 'check data received') and
		ok($j->{data}{sent} >= 0, 'check data sent') and
		ok($response_code, 'check response code 200')
	);
}

sub check_stats_ssl {
	my ($j, $count) = @_;

	return (
		check_stats($j, $count) and
		ok($j->{ssl}{handshaked} == $count, 'check ssl handshaked')
	);
}

sub check_server_cert_type_zone {
	my $j = get_json('/status/');

	my $server_zones = $j->{http}{server_zones};
	my $location_zones = $j->{http}{location_zones};

	ok(check_stats_ssl($server_zones->{server_cert_type}, 0),
		"check 'server_cert_type' server zone");

	ok(check_stats($location_zones->{server_cert_type}, 0),
		"check 'server_cert_type' location zone");

	ok(check_stats_ssl($server_zones->{RSA}, 2),
		"check 'RSA' server zone");
	ok(check_stats_ssl($server_zones->{ECDSA}, 2),
		"check 'ECDSA' server zone");

	ok(check_stats($location_zones->{RSA}, 2),
		"check 'RSA' location zone");
	ok(check_stats($location_zones->{ECDSA}, 2),
		"check 'ECDSA' location zone");
}

sub check_single_zone {
	my $j = get_json('/status/');

	ok(check_stats_ssl($j->{http}{server_zones}{single}, 10),
		"check 'single' server zone");
	ok(check_stats($j->{http}{location_zones}{single}, 10),
		"check 'single' location zone");

	$j = get_json('/status/http/server_zones/single');
	ok(check_stats_ssl($j, 10), "check 'single' server zone directly");

	$j = get_json('/status/http/location_zones/single');
	ok(check_stats($j, 10), "check 'single' location zone directly");
}

sub test_single_zone {
	for (1 .. 5) {
		get('/', 8085);
		get('/', 8086);
	}

	check_single_zone();
}

sub check_sni_zone {
	my $j = get_json('/status/');

	my $server_zones = $j->{http}{server_zones};
	my $location_zones = $j->{http}{location_zones};

	ok(check_stats_ssl($server_zones->{sni}, 10), "check 'sni' server zone");

	ok(check_stats($location_zones->{sni}, 10), "check 'sni' location zone");

	for (1 .. 5) {
		my $a_zone = "$_.sni.$a";
		my $b_zone = "$_.sni.$b";

		ok(check_stats_ssl($server_zones->{$a_zone}, 2),
			"check '$a_zone' server zone");
		ok(check_stats_ssl($server_zones->{$b_zone}, 2),
			"check '$b_zone' server zone");

		ok(not (exists $server_zones->{"f.$a_zone"}),
			"'f.$a_zone' server zone does not exist");
		ok(not (exists $server_zones->{"f.$b_zone"}),
			"'f.$b_zone' server zone does not exist");

		ok(check_stats($location_zones->{$a_zone}, 2),
			"check '$a_zone' location zone");
		ok(check_stats($location_zones->{$b_zone}, 2),
			"check '$b_zone' location zone");

		ok(not (exists $location_zones->{"f.$a_zone"}),
			"'f.$a_zone' location zone does not exist");
		ok(not (exists $server_zones->{"f.$b_zone"}),
			"'f.$b_zone' location zone does not exist");
	}
}

sub test_sni_zone {
	for (1 .. 5) {
		get('/', 8087, "$_.sni.$a");
		get('/', 8088, "$_.sni.$b");
	}

	for (1 .. 5) {
		get('/', 8087, "$_.sni.$a");
		get('/', 8087, "f.$_.sni.$a");
		get('/', 8088, "$_.sni.$b");
		get('/', 8088, "f.$_.sni.$b");
	}

	check_sni_zone();
}

sub check_host_zone {
	my $j = get_json('/status/');

	my $server_zones = $j->{http}{server_zones};
	my $location_zones = $j->{http}{location_zones};

	ok($server_zones->{'*.a.example.com'}{ssl}{handshaked} == 30,
		"check '*.a.example.com' zone ssl stats");

	ok(check_stats($server_zones->{a_host}, 5),
		"check 'a_host' server zone");
	ok(check_stats($server_zones->{b_host}, 5),
		"check 'b_host' server zone");

	ok(check_stats($location_zones->{a_host}, 5),
		"check 'a_host' location zone");
	ok(check_stats($location_zones->{b_host}, 5),
		"check 'b_host' location zone");

	for (1 .. 5) {
		my $a_zone = "$_.$a";
		my $b_zone = "$_.$b";

		my $zj = get_json("/status/http/server_zones/$a_zone");
		ok(check_stats($zj, 2), "check '$a_zone' server zone directly");

		$zj = get_json("/status/http/server_zones/$b_zone");
		ok(check_stats($zj, 2), "check '$b_zone' server zone directly");

		ok(check_stats($server_zones->{$a_zone}, 2),
			"check '$a_zone' server zone");
		ok(check_stats($server_zones->{$b_zone}, 2),
			"check '$b_zone' server zone");

		ok(not (exists $server_zones->{"f.$a_zone"}),
			"'f.$a_zone' server zone does not exist");
		ok(not (exists $server_zones->{"f.$b_zone"}),
			"'f.$b_zone' server zone does not exist");

		$zj = get_json("/status/http/location_zones/$a_zone");
		ok(check_stats($zj, 2), "check '$a_zone' location zone directly");

		$zj = get_json("/status/http/location_zones/$b_zone");
		ok(check_stats($zj, 2), "check '$b_zone' location zone directly");

		ok(check_stats($location_zones->{$a_zone}, 2),
			"check '$a_zone' location zone");
		ok(check_stats($location_zones->{$b_zone}, 2),
			"check '$b_zone' location zone");

		ok(not (exists $location_zones->{"f.$a_zone"}),
			"'f.$a_zone' location zone does not exist");
		ok(not (exists $server_zones->{"f.$b_zone"}),
			"'f.$b_zone' location zone does not exist");
	}
}

sub test_host_zone {
	for (1 .. 5) {
		get('/', 8084, host => "$_.$a");
		get('/', 8084, host => "$_.$b");
	}

	for (1 .. 5) {
		get('/', 8084, host => "$_.$a");
		get('/', 8084, host => "f.$_.$a");
		get('/', 8084, host => "$_.$b");
		get('/', 8084, host => "f.$_.$b");
	}

	check_host_zone();
}

sub check_uri_zone {
	my $j = get_json('/status/');

	my $server_zones = $j->{http}{server_zones};
	my $location_zones = $j->{http}{location_zones};

	ok(check_stats($server_zones->{uri}, 17), "check 'uri' server zone");

	ok(check_stats($location_zones->{uri}, 17), "check 'uri' location zone");

	for my $i (1 .. 5) {
		for my $j (1 .. 3) {
			ok(check_stats($server_zones->{"/$i.$j"}, 1),
				"check '/$i.$j' server zone");

			ok(not (exists $server_zones->{"/$i.$j.f"}),
				"'/$i.$j.f' server zone does not exist");

			ok(check_stats($location_zones->{"/$i.$j"}, 1),
				"check '/$i.$j' location zone");

			ok(not (exists $location_zones->{"/$i.$j.f"}),
				"'/$i.$j.f' location zone does not exist");
		}
	}
}

sub test_uri_zone {
	for my $i (1 .. 5) {
		for my $j (1 .. 3) {
			get("/$i.$j", 8080 + $j);
		}
	}

	for my $i (1 .. 5) {
		for my $j (1 .. 3) {
			get("/$i.$j.f", 8080 + $j);
		}
	}

	my $uri = '/' . ('a' x 254);

	for my $i (1 .. 3) {
		get($uri, 8081);
		$uri .= 'a';
	}

	check_uri_zone();
}

sub check_locations_zone {
	my $j = get_json('/status/');

	my $location_zones = $j->{http}{location_zones};

	ok(check_stats($location_zones->{locations}, 10),
		"check 'locations' location zone");

	for (1 .. 10) {
		ok(check_stats($location_zones->{"/location_$_"}, 2),
			"check 'location_$_' location zone");
	}

	for (11 .. 20) {
		ok(not (exists $location_zones->{"/location_$_"}),
			"'/location_$_' location zone does not exist");
	}
}

sub test_locations_zone {
	for (1 .. 20) {
		get("/location_$_", 8096);
	}

	for (1 .. 10) {
		get("/location_$_", 8096);
	}

	check_locations_zone();
}

sub check_host_uri_zone {
	my $j = get_json('/status/');

	my $server_zones = $j->{http}{server_zones};
	my $location_zones = $j->{http}{location_zones};

	ok($server_zones->{'*.example.com'}{ssl}{handshaked} == 50,
		"check '*.a.example.com' zone ssl stats");

	ok(check_stats($server_zones->{hosts}, 0), "check 'hosts' server zone");
	ok(check_stats($server_zones->{localhost}, 10),
		"check 'localhost' server zone");
	ok(check_stats($server_zones->{$a}, 20), "check '$a' server zone");
	ok(check_stats($server_zones->{$b}, 20), "check '$b' server zone");

	ok(check_stats($location_zones->{uris}, 10),
		"check 'uris' location zone");
	ok(check_stats($location_zones->{loc1}, 10),
		"check 'loc1' location zone");
	ok(check_stats($location_zones->{loc2}, 10),
		"check 'loc2' location zone");

	for (1 .. 5) {
		ok(check_stats($location_zones->{"/loc_$_.1"}, 2),
			"check 'loc_/$_.1' location zone");
		ok(check_stats($location_zones->{"/loc_$_.2"}, 2),
			"check 'loc_/$_.2' location zone");

		ok(not (exists $location_zones->{"/loc_$_.1.f"}),
			"'/loc_$_.1.f' location zone does not exist");
		ok(not (exists $location_zones->{"/loc_$_.2.f"}),
			"'/loc_$_.2.f' location zone does not exist");
	}
}

sub test_host_uri_zone {
	for (1 .. 5) {
		get("/loc_$_.1", 8095, host => $a);
		get("/loc_$_.2", 8095, 'localhost', $a);

		get("/loc1", 8095, 'localhost', $a);
		get("/loc2", 8095, 'localhost', $a);
	}

	for (1 .. 5) {
		get("/loc_$_.1.f", 8095, 'localhost', $b);
		get("/loc_$_.2.f", 8095, 'localhost', $b);

		get("/loc1", 8095, 'localhost', $b);
		get("/loc2", 8095, 'localhost', $b);
	}

	for (1 .. 5) {
		get("/loc_$_.1", 8095);
		get("/loc_$_.2", 8095);
	}

	check_host_uri_zone();
}

sub check_sni_host_zone {
	my $j = get_json('/status/');

	ok(check_stats_ssl($j->{http}{server_zones}{a_sni_host}, 1),
		"check 'a_sni_host' server zone");
	ok(check_stats_ssl($j->{http}{server_zones}{b_sni_host}, 1),
		"check 'b_sni_host' server zone");
}

sub test_sni_host_zone {
	get('/', 8097, 'a.com', 'b.com');
	get('/', 8097, 'b.com', 'a.com');

	check_sni_host_zone();
}

sub get {
	my ($uri, $port, $sni, $host) = @_;
	$sni ||= 'localhost';
	$host ||= 'localhost';

	my $s = Test::Nginx::HTTP3->new($port, sni => $sni);

	$s->insert_literal(':path', $uri);

	my $sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => $uri, mode => 0, dyn => 1 },
	{ name => ':authority', value => $host, mode => 4 }]});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
	@$frames = grep { $_->{type} =~ "HEADERS|DATA" } @$frames;

	my $frame = shift @$frames;

	is($frame->{headers}->{':status'}, 200,
		"request OK, uri '$uri', sni '$sni', host '$host'");
}

###############################################################################
