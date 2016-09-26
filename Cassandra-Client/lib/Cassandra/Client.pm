package Cassandra::Client;

use 5.008;
use strict;
use warnings;

our $VERSION = '0.05';

use Cassandra::Client::Config;
use Cassandra::Client::Connection;
use Cassandra::Client::Util qw/series/;
use Cassandra::Client::AsyncIO;
use Cassandra::Client::AsyncAnyEvent;
use Cassandra::Client::Metadata;
use Cassandra::Client::Pool;
use List::Util qw/shuffle/;
use Promises qw/deferred/;
use Clone qw/clone/;

sub new {
    my ($class, %args)= @_;

    my $self= bless {
        connected         => 0,
        connect_callbacks => undef,
        shutdown          => 0,
        shutdown_cb       => undef,
    }, $class;

    my $options= Cassandra::Client::Config->new(
        \%args
    );
    my $async_class= $options->{anyevent} ? "Cassandra::Client::AsyncAnyEvent" : "Cassandra::Client::AsyncIO";
    my $async_io= $async_class->new(
        options => $options,
    );
    my $metadata= Cassandra::Client::Metadata->new(
        options => $options,
    );
    my $pool= Cassandra::Client::Pool->new(
        client   => $self,
        options  => $options,
        metadata => $metadata,
    );

    $self->{options}= $options;
    $self->{async_io}= $async_io;
    $self->{metadata}= $metadata;
    $self->{pool}= $pool;

    return $self;
}

sub _connect {
    my ($self, $callback)= @_;
    return _cb($callback) if $self->{connected};
    return _cb($callback, 'Cannot connect: shutdown() has been called') if $self->{shutdown};

    push @{$self->{connect_callbacks}||=[]}, $callback;
    if ($self->{connecting}++) {
        return;
    }

    my @contact_points= shuffle @{$self->{options}{contact_points}};
    my $last_error= "No hosts to connect to";

    my $next_connect;
    $next_connect= sub {
        my $contact_point= shift @contact_points;
        if (!$contact_point) {
            delete $self->{connecting};
            return _cb($_, "Unable to connect to any Cassandra server. Last error: $last_error") for @{delete $self->{connect_callbacks}};
        }

        my $connection= Cassandra::Client::Connection->new(
            client => $self,
            options => $self->{options},
            host => $contact_point,
            async_io => $self->{async_io},
            metadata => $self->{metadata},
        );

        series([
            sub {
                my ($next)= @_;
                $connection->connect($next);
            },
            sub {
                my ($next)= @_;
                $self->{pool}{datacenter}= $connection->{datacenter}; #XXX
                $self->{pool}->add($connection);
                $self->{pool}->warmup($next);
            },
        ], sub {
            my $error= shift;
            if ($error) {
                $last_error= "On $contact_point: $error";
                return $next_connect->();
            }

            $self->{connected}= 1;
            delete $self->{connecting};
            _cb($_) for @{delete $self->{connect_callbacks}};
        });
    };
    $next_connect->();

    return;
}

sub _shutdown {
    my ($self, $callback)= @_;

    if ($self->{shutdown_cb}) {
        push @{$self->{shutdown_cb}}, $callback;
        return;
    }
    if ($self->{shutdown} && !$self->{shutdown_cb}) {
        return _cb($callback);
    }
    if (!$self->{connected}) {
        return _cb($callback, 'Cannot shutdown: not connected');
    }

    $self->{shutdown}= 1;
    $self->{connected}= 0;
    $self->{shutdown_cb}= [$callback];

    $self->{pool}->shutdown(sub {
        my ($error)= @_;
        my $cb= $self->{shutdown_cb};
        $self->{shutdown_cb}= undef;
        _cb($_, $error) for @$cb;
    });

    return;
}

sub is_active {
    my ($self)= @_;
    return 0 unless $self->{connected};
    return 1;
}

sub _disconnected {
    my ($self, $connid)= @_;
    $self->{pool}->remove($connid);
    return;
}

sub _handle_topology_change {
    my ($self, $change, $ipaddress)= @_;
    if ($change eq 'NEW_NODE') {
        $self->{pool}->event_added_node($ipaddress);
    } elsif ($change eq 'REMOVED_NODE') {
        $self->{pool}->event_removed_node($ipaddress);
    } else {
        warn "Received unknown topology change: $change for $ipaddress";
    }
}

sub _handle_status_change {
    my ($self, $change, $ipaddress)= @_;
    # XXX Ignored, for now
    $self->{pool}->connect_if_needed;
}



# Query functions
sub _prepare {
    my ($self, $callback, $query)= @_;

    # Fast path: we're already done
    if ($self->{metadata}->is_prepared(\$query)) {
        return _cb($callback);
    }

    # XXX: Do we really need the duplication of having a second fast path for prepare()?
    goto SLOWPATH if !$self->{connected};

    my $connection= $self->{pool}->get_one;
    goto SLOWPATH if !$connection;

    $connection->prepare(sub {
        my ($error)= @_;
        if ($error && ref($error) && $error->retryable) {
            return $self->_prepare_slowpath($callback, $query);
        } else {
            return _cb($callback, $error);
        }
    }, $query);

    return;

SLOWPATH:
    return $self->_prepare_slowpath($callback, $query);
}

sub _prepare_slowpath {
    my ($self, $callback, $query)= @_;

    # XXX Do we need to retry prepares on other hosts if they fail for reasons other than bad CQL?

    series([
        sub {
            my ($next)= @_;
            $self->_connect($next);
        }, sub {
            my ($next)= @_;
            $self->{pool}->get_one_cb($next);
        }, sub {
            my ($next, $connection)= @_;
            $connection->prepare($next);
        }
    ], sub {
        my ($error)= @_;
        return _cb($callback, $error);
    });
    return;
}

sub _execute {
    my ($self, $callback, $query, $params, $attribs)= @_;

    my $params_copy= $params ? clone($params) : undef;
    my $attribs_copy= $attribs ? clone($attribs) : undef;

    goto SLOWPATH if !$self->{connected};

    my $connection= $self->{pool}->get_one;
    goto SLOWPATH if !$connection;

    $connection->execute_prepared(sub {
        my ($error, $result)= @_;
        if ($error && ref($error) && $error->retryable) {
            return $self->_execute_slowpath($callback, $query, $params_copy, $attribs_copy);
        } else {
            _cb($callback, $error, $result);
        }
        return;
    }, \$query, $params_copy, $attribs_copy);

    return;

SLOWPATH:
    return $self->_execute_slowpath($callback, $query, $params_copy, $attribs_copy);
}

sub _execute_slowpath {
    my ($self, $callback, $query, $params_copy, $attribs_copy)= @_;

    series([
        sub {
            my ($next)= @_;
            $self->_connect($next);
        }, sub {
            my ($next)= @_;
            $self->{pool}->get_one_cb($next);
        }, sub {
            my ($next, $connection)= @_;
            $connection->execute_prepared($next, \$query, $params_copy, $attribs_copy);
        }
    ], sub {
        my ($error, $result)= @_;
        _cb($callback, $error, $result);
        return;
    });
    return;
}

sub _batch {
    my ($self, $callback, $queries, $attribs)= @_;

    my $queries_copy= $queries ? clone($queries) : undef;
    my $attribs_copy= $attribs ? clone($attribs) : undef;

    goto SLOWPATH if !$self->{connected};

    my $connection= $self->{pool}->get_one;
    goto SLOWPATH if !$connection;

    $connection->execute_batch(sub {
        my ($error, $result)= @_;
        if ($error && ref($error) && $error->retryable) {
            return $self->_batch_slowpath($callback, $queries_copy, $attribs_copy);
        } else {
            _cb($callback, $error, $result);
        }
        return;
    }, $queries_copy, $attribs_copy);

    return;

SLOWPATH:
    return $self->_batch_slowpath($callback, $queries_copy, $attribs_copy);
}

sub _batch_slowpath {
    my ($self, $callback, $queries_copy, $attribs_copy)= @_;

    series([
        sub {
            my ($next)= @_;
            $self->_connect($next);
        }, sub {
            my ($next)= @_;
            $self->{pool}->get_one_cb($next);
        }, sub {
            my ($next, $connection)= @_;
            $connection->execute_batch($next, $queries_copy, $attribs_copy);
        }
    ], sub {
        my ($error, $result)= @_;
        _cb($callback, $error, $result);
        return;
    });
    return;
}

# Utility functions that wrap query functions
sub _each_page {
    my ($self, $callback, $query, $params, $attribs, $page_callback)= @_;

    my $params_copy= $params ? clone($params) : undef;
    my $attribs_copy= $attribs ? clone($attribs) : undef;

    my $next_page; $next_page= sub {
        $self->_execute(sub {
            # Completion handler, with page data (or an error)
            my ($error, $result)= @_;
            return _cb($callback, $error) if $error;

            my $next_page_id= $result->next_page;
            _cb($page_callback, $result); # Note that page_callback doesn't get an error argument, that's intentional
            if ($next_page_id) {
                $attribs_copy->{page}= $next_page_id;
                $next_page->();
                return;
            } else {
                # Done!
                return _cb($callback);
            }
        }, $query, $params_copy, $attribs_copy);
    };
    $next_page->();

    return;
}

sub _wait_for_schema_agreement {
    my ($self, $callback)= @_;

    # Let's face it, perf doesn't matter on this method :-)
    $self->{pool}->get_one_cb(sub {
        my ($error, $connection)= @_;
        return _cb($callback, $error) if $error;

        $connection->wait_for_schema_agreement(sub {
            return _cb($callback, @_);
        });
    });
}


# Utility functions for callers
sub _cb {
    my $cb= shift;
    eval {
        &$cb; 1
    } or do {
        my $error= $@ || "unknown error";
        warn "Ignoring unhandled exception in callback: $error";
    };

    return;
}

sub _mksync { # Translates an asynchronous call into something that looks like Perl
    my ($sub)= @_;
    return sub {
        my $self= shift;
        $sub->($self, $self->{async_io}->wait(my $w), @_);
        my ($err, @output)= $w->();
        if ($err) { die $err; }
        return @output;
    };
}

sub _mkcall { # Basically _mksync, but returns the error instead of dying
    my ($sub)= @_;
    return sub {
        my $self= shift;
        $sub->($self, $self->{async_io}->wait(my $w), @_);
        return $w->();
    };
}

sub _mkpromise {
    my ($sub)= @_;
    return sub {
        my $self= shift;
        my $deferred= deferred;

        $sub->($self, sub {
            my ($error, @output)= @_;
            if ($error) {
                $deferred->reject($error);
            } else {
                $deferred->resolve(@output);
            }
        }, @_);

        return $deferred->promise;
    };
}

sub _mkfuture {
    my ($sub)= @_;
    return sub {
        my $self= shift;
        $sub->($self, $self->{async_io}->wait(my $w), @_);
        return sub {
            my ($error, @output)= $w->();
            if ($error) { die $error; }
            return @output;
        };
    }
}

sub _mkfuture_call {
    my ($sub)= @_;
    return sub {
        my $self= shift;
        $sub->($self, $self->{async_io}->wait(my $w), @_);
        return $w;
    }
}

PUBLIC_METHODS: {
    no strict 'refs';
    for (qw/
        batch
        connect
        execute
        each_page
        prepare
        shutdown
        wait_for_schema_agreement
    /) {
        *{$_}=               _mksync        (\&{"_$_"});
        *{"call_$_"}=        _mkcall        (\&{"_$_"});
        *{"async_$_"}=       _mkpromise     (\&{"_$_"});
        *{"future_$_"}=      _mkfuture      (\&{"_$_"});
        *{"future_call_$_"}= _mkfuture_call (\&{"_$_"});
    }
}

1;

=pod

=head1 NAME

Cassandra::Client - Perl interface to Cassandra's native protocol

=head1 EXAMPLE

    use Cassandra::Client;
    my $client= Cassandra::Client->new(
        contact_points => [ '127.0.0.1', '192.168.0.1' ],
        username => "my_user",
        password => "my_password",
        keyspace => "my_keyspace",
    );
    $client->connect;

    $client->each_page("SELECT id, column FROM my_table WHERE id=?", [ 5 ], undef, sub {
        for my $row (@{shift->rows}) {
            my ($id, $column)= @$row;
            say "$id: $column";
        }
    });

=head1 DESCRIPTION

C<Cassandra::Client> is a Perl library giving its users access to the Cassandra database, through the native protocol. Both synchronous and asynchronous querying is supported, through various common calling styles.

=head1 METHODS

=over

=item Cassandra::Client->new(%options)

Create a new C<Cassandra::Client> instance, with the given options.

=over

=item contact_points

B<Required.> Arrayref of seed hosts to use when connecting. Specify more than one for increased reliability. This array is shuffled before use, so that random hosts are picked from the array.

=item keyspace

Default keyspace to use on all underlying connections. Can be overridden by querying for specific keyspaces, eg C<SELECT * FROM system.peers>.

=item anyevent

Should our internal event loop be based on AnyEvent, or should we just use our own? A true value means enable AnyEvent. Needed for promises to work.

=item port

Port number to use. Defaults to C<9042>.

=item cql_version

CQL version to use. Defaults to the version the server is running. Override only if your client has specific CQL requirements.

=item compression

Compression method to use. Defaults to the best available version, based on server and client support. Possible values are C<snappy>, C<lz4>, and C<none>.

=item default_consistency

Default consistency level to use. Defaults to C<one>. Can be overridden on a query basis as well, by passing a C<consistency> attribute.

=item max_page_size

Default max page size to pass to the server. This defaults to C<5000>. Note that large values can cause trouble on Cassandra. Can be overridden by passing C<page_size> in query attributes.

=item max_connections

Maximum amount of connections to keep open in the Cassandra connection pool. Defaults to C<2> for historical reasons, will be raised in a future version.

=item timer_granularity

Timer granularity used for timeouts. Defaults to C<0.1> (100ms). Change this if you're setting timeouts to values lower than a second.

=item request_timeout

Maximum time to wait for a query, in seconds. Defaults to C<11>.

=item warmup

Whether to connect to the full cluster in C<connect()>, or delay that until queries come in.

=back

=item $client->batch($queries[, $attributes])

Run one or more queries, in a batch, on Cassandra. Queries must be specified as an arrayref of C<[$query, \@bind]> pairs.

Defaults to a I<logged> batch, which can be overridden by passing C<logged>, C<unlogged> or C<counter> as the C<batch_type> attribute.

    $client->batch([
        [ "INSERT INTO my_table (a, b) VALUES (?, ?)", [ $row1_a, $row1_b ] ],
        [ "INSERT INTO my_table (a, b) VALUES (?, ?)", [ $row2_a, $row2_b ] ],
    ], { batch_type => "unlogged" });

=item $client->execute($query[, $bound_parameters[, $attributes]])

Executes a single query on Cassandra, and fetch the results (if any).

For queries that have large amounts of result rows and end up spanning multiple pages, C<each_page> is the function you need. C<execute> does not handle pagination, and may end up missing rows unless pagination is implemented by its user through the C<page> attribute.

    $client->execute(
        "UPDATE my_table SET column=? WHERE id=?",
        [ 2, 5 ],
        { consistency => "quorum" },
    );

=item $client->each_page($query, $bound_parameters, $attributes, $page_callback)

Executes a query and invokes C<$page_callback> with each page of the results, represented as L<Cassandra::Client::ResultSet> objects.

    # Downloads the entire table from the database, even if it's terabytes in size
    $client->each_page( "SELECT id, column FROM my_table", undef, undef, sub {
        my $page= shift;
        for my $row (@{$page->rows}) {
            say $row->[0];
        }
    });

=item $client->prepare($query)

Prepares a query on the server. C<execute> and C<each_page> already do this internally, so this method is only useful for preloading purposes (and to check whether queries even compile, I guess).

=item $client->shutdown()

Disconnect all connections and abort all current queries. After this, the C<Cassandra::Client> object considers itself shut down and must be reconstructed with C<new()>.

=item $client->wait_for_schema_agreement()

I<Not implemented yet, this just does a C<sleep 1>!> Wait until all nodes agree on the schema version. Useful after changing table or keyspace definitions.

=back

=head1 (A?)SYNCHRONOUS

It's up to the user to choose which calling style to use: synchronous, asynchronous with promises, or through returned coderefs.

=head2 Synchronous

All C<Cassandra::Client> methods are available as synchronous methods by using their normal names. For example, C<< $client->connect(); >> will block until the client has connected. Similarly, C<< $client->execute($query) >> will wait for the query response. These are arguably not the fastest variants (there's no parallelism in queries) but certainly the most convenient.

    my $client= Cassandra::Client->new( ... );
    $client->connect;
    $client->execute("INSERT INTO my_table (id, value) VALUES (?, ?) USING TTL ?",
        [ 1, "test", 86400 ],
        { consistency => "quorum" });

=head2 Promises

C<Cassandra::Client> methods are also available as promises (see perldoc L<Promises>). This integrates well with other libraries that deal with promises or asynchronous callbacks. Note that for promises to work, C<AnyEvent> is required, and needs to be enabled by passing C<< anyevent => 1 >> to C<< Cassandra::Client->new() >>.

Promise variants are available by prefixing method names with C<async_>, eg. C<async_connect>, C<async_execute>, etc. The usual result of the method is passed to the promise's success handler, or to the failure handler if there was an error.

    # Asynchronously pages through the result set, processing data as it comes in.
    my $promise= $client->async_each_page("SELECT id, column FROM my_table WHERE id=?", [ 5 ], undef, sub {
        for my $row (@{shift->rows}) {
            my ($id, $column)= @$row;
            say "Row: $id $column";
        }
    })->then(sub {
        say "We finished paging through all the rows";
    }, sub {
        my $error= shift;
    });

Promises normally get resolved from event loops, so for this to work you need one. Normally you would deal with that by collecting all your promises and then waiting for that :

    use Promises qw/collect/;
    use AnyEvent;

    my @promises= ( ... ); # See other examples
    my $condvar= AnyEvent->condvar;

    collect(@promises)->then(sub {
        $condvar->send;
    }, sub {
        my $error= shift;
        warn "Unhandled error! $error";
        $condvar->send;
    });
    $condvar->recv; # Wait for the promsie to resolve or fail

How you integrate this into your infrastructure is of course up to you, and beyond the scope of the C<Cassandra::Client> documentation.

=head2 Coderefs

These are the simplest form of asynchronous querying in C<Cassandra::Client>. Instead of dealing with complex callback resolution, the client simply returns a coderef that, once invoked, returns what the original method would have retruned.

The variants are available by prefixing method names with C<future_>, eg. C<future_connect>, C<future_execute>, etc. These methods return a coderef.

    my $coderef= $client->future_execute("INSERT INTO table (id, value) VALUES (?, ?), [ $id, $value ]);

    # Do other things
    ...

    # Wait for the query to finish
    $coderef->();

Upon errors, the coderef will die, just like the synchronous methods would. Because of this, invoking the coderef immediately after getting it is equal to using the synchronous methods :

    # This :
    $client->connect;

    # Is the same as :
    $client->future_connect->();

When used properly, coderefs can give a modest performance boost, but their real value is in the ease of use compared to promises.

=head1 CAVEATS, BUGS, TODO

=over

=item *

Thread support is untested. Use at your own risk.

=item *

The C<timestamp> format is implemented naively by returning
milliseconds since the UNIX epoch. In Perl you get this number through
C<time() * 1000>. Trying to save times as C<DateTime> objects or
strings will not work, and will likely result in warnings and
unexpected behavior.

=back

=head1 LICENSE

Copyright (C) 2016 L<Tom van der Woerdt|mailto:tvdw@cpan.org>

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.
