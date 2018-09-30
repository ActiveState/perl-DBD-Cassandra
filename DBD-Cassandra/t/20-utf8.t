use 5.010;
use warnings;
use strict;
use File::Basename qw//; use lib File::Basename::dirname(__FILE__).'/lib';
use TestCassandra;
use Test::More;

plan skip_all => "Missing Cassandra test environment" unless TestCassandra->is_ok;
plan tests => 2;

my $dbh= TestCassandra->get(";keyspace=dbd_cassandra_tests");
ok($dbh);

$dbh->do('create table if not exists test_utf8 (id bigint primary key, str varchar)');

my $test_string= "";
utf8::decode($test_string);
for (1..100) {
    $test_string .= chr(int(rand(30000)+1000));
}

$dbh->do("insert into test_utf8 (id, str) values (?,?)", undef, 1, $test_string);
my $row= $dbh->selectrow_arrayref('select str from test_utf8 where id=1');
ok($row->[0] eq $test_string);

$dbh->disconnect;
