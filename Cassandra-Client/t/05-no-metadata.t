#!perl
use 5.008;
use strict;
use warnings;
use Test::More;
use Cassandra::Client;

plan skip_all => "CASSANDRA_HOST not set" unless $ENV{CASSANDRA_HOST};

my $client= Cassandra::Client->new( contact_points => [split /,/, $ENV{CASSANDRA_HOST}], username => $ENV{CASSANDRA_USER}, password => $ENV{CASSANDRA_AUTH}, anyevent => (rand()<.5) );
$client->connect();

{
    my ($result)= $client->execute("list users");
    my $headers= $result->column_names;
    ok(0+@$headers > 1);
    ok($_) for @$headers;
}

done_testing;
