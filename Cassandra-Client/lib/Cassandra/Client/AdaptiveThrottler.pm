package Cassandra::Client::AdaptiveThrottler;

use 5.008;
use strict;
use warnings;
use Time::HiRes ();

sub new {
    my ($class, %args)= @_;
    return bless {
        ratio => $args{ratio} || 2,
        time => $args{time} || 120,

        window => [],
        window_success => 0,
        window_total => 0,
    }, $class;
}

sub _process_window {
    my ($self)= @_;
    my $now= Time::HiRes::time;
    while (@{$self->{window}} && $self->{window}[0][0] < $now) {
        my $entry= shift @{$self->{window}};
        $self->{window_total}--;
        $self->{window_success}-- unless $entry->[1];
    }
    return;
}

sub should_fail {
    my ($self)= @_;
    $self->_process_window;

    my $fail= ( rand() < (($self->{window_total} - ($self->{ratio} * $self->{window_success})) / ($self->{window_total} + 1)) );
    return unless $fail;

    $self->count(1);
    return 1;
}

sub count {
    my ($self, $error)= @_;
    $self->{window_total}++;
    push @{$self->{window}}, [ Time::HiRes::time()+$self->{time}, !!$error ];
    $self->{window_success}++ unless ref($error) && !$error->retryable;
    return;
}

1;
