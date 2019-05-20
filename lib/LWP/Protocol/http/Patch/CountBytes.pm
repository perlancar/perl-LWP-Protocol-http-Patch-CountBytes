package LWP::Protocol::http::Patch::CountBytes;

# DATE
# VERSION

use 5.010001;
use strict 'subs', 'vars';
no warnings;
use Log::ger;

use Module::Patch ();
use base qw(Module::Patch);

use Scalar::Util qw(refaddr);

our $bytes_in = -1;
our $bytes_out = -1;
our %config;
our %package_already_patched; # key: package
our %sock_objs; # key = address of objects

sub _get_byte_size {
    my($self, @strings) = @_;
    my $bytes = 0;

    {
        use bytes;
        for my $string (@strings) {
            $bytes += length($string);
        }
    }

    return $bytes;
}

sub _patch_socket_pkg {
    my $pkg = shift;

    return if $package_already_patched{$pkg}++;

    my $orig_send_exists = exists &{"$pkg\::send"};
    my $orig_send        = \&{"$pkg\::send"};
    my $orig_recv_exists = exists &{"$pkg\::recv"};
    my $orig_recv        = \&{"$pkg\::recv"};

    say "D:patching $pkg\::send ...";
    *{"$pkg\::send"} = sub {
        my $self = $_[0];
        my $bytes_actually_sent;

        if ($orig_send_exists) {
            # XXX by default socket returns number of bytes sent, but if it has
            # been binmode()-ed, it will return number of characters instead. we
            # haven't handled this.
            $bytes_actually_sent = $orig_send->(@_);
        } else {
            shift;
            $bytes_actually_sent = $self->SUPER::send(@_);
        }
        $bytes_out += $bytes_actually_sent
            if 1||$sock_objs{refaddr $self}; # this only counts sockets used by LWP
        $bytes_actually_sent;
    };

    say "D:patching $pkg\::recv ...";
    *{"$pkg\::recv"} = sub {
        my ($self, $scalar, $len, $flags) = @_;

        my $res;
        if ($orig_recv_exists) {
            $res = $orig_recv->($self, $scalar, $len, $flags);
        } else {
            $res = $self->SUPER::recv($scalar, $len, $flags);
        }
        $bytes_in += _get_byte_size($scalar)
            if 1||$sock_objs{refaddr $self}; # this only counts sockets used by LWP
        $res;
    };
}

sub patch_data {
    return {
        v => 3,
        config => {
        },
        patches => [
            {
                action => 'wrap',
                #mod_version => qr/^6\./,
                sub_name => '_new_socket',
                code => sub {
                    my $ctx  = shift;
                    my $orig = $ctx->{orig};

                    my $sock = $ctx->{orig}->(@_);
                    my $sock_pkg = ref($sock);

                    # patch send() and recv() of the socket's package (manually
                    # and not using Module::Patch framework, for simplicity, for
                    # now)
                    unless (!$sock_pkg # shouldn't happen
                                || $package_already_patched{$sock_pkg}++) {
                        _patch_socket_pkg($sock_pkg);
                    }
                    $sock_objs{refaddr $sock}++;
                    $sock->send("test");
                    $sock;
                },
            },
        ],
        after_patch => sub {
            _patch_socket_pkg("LWP::Protocol::http::Socket");
        },
    };
}

1;
# ABSTRACT: Count bytes in/out (bandwidth, data transfer) of HTTP traffic

=head1 SYNOPSIS

 use LWP::Protocol::http::Patch::CountBytes;

 # ... use LWP

 printf "bytes in : %9d\n", $LWP::Protocol::http::Patch::CountBytes::bytes_in;
 printf "bytes out: %9d\n", $LWP::Protocol::http::Patch::CountBytes::bytes_out;


=head1 DESCRIPTION

Caveats: HTTPS traffic is currently not counted properly, because of the SSL
layer.


=head1 SEE ALSO

L<IO::Socket::ByteCounter>

=cut
