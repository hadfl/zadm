package Zadm::Validator;
use Mojo::Base -base, -signatures;

use Mojo::Log;
use Mojo::Exception;
use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(b64_encode);
use Bytes::Random::Secure::Tiny;
use File::Basename qw(basename dirname);
use Regexp::IPv4 qw($IPv4_re);
use Regexp::IPv6 qw($IPv6_re);
use Zadm::Privilege qw(:CONSTANTS privSet);
use Zadm::Utils;

# constants
my @VNICATTR = qw(link over vid);
my $FWPATH   = '/usr/share/bhyve/firmware/';

my %vcpuOptions = (
    sockets => undef,
    cores   => undef,
    threads => undef,
    maxcpus => undef,
);

my %unitFactors = (
    b   => 1,
    k   => 1024,
    m   => 1024 ** 2,
    g   => 1024 ** 3,
    t   => 1024 ** 4,
    p   => 1024 ** 5,
    e   => 1024 ** 6,
);

# static private methods
my $numeric = sub($val) {
    return $val =~ /^\d+$/;
};

my $toBytes = sub($size = '') {
    return 0 if !$size;

    my $suffixes = join '', keys %unitFactors;

    my ($val, $suf) = $size =~ /^([\d.]+)([$suffixes])?$/i
        or return 0;

    return int ($val * $unitFactors{lc ($suf || 'b')});
};

my $toHash = sub($key, $val) {
    # transform scalars into hashes
    return $key && $val && !ref $val ? { $key => $val } : $val;
};

my $checkBlockSize = sub($blkSize, $name, $min, $max) {
    my $val = $toBytes->($blkSize)
        or return "$name '$blkSize' not valid";

    $val >= $toBytes->($min)
        or return "$name '$blkSize' not valid. Must be greater or equal than $min";
    $val <= $toBytes->($max)
        or return "$name '$blkSize' not valid. Must be less or equal than $max";
    ($val & ($val - 1))
        and return "$name '$blkSize' not valid. Must be a power of 2";

    return undef;
};

# attributes
has log     => sub { Mojo::Log->new(level => 'debug') };
has utils   => sub($self) { Zadm::Utils->new(log => $self->log) };
has vnicmap => sub {
    my $i = 0;
    return { map { $_ => $i++ } @VNICATTR };
};

sub regexp($self, $rx, $msg = 'invalid value') {
    return sub($value, @) {
        return $value =~ /$rx/ ? undef : "$msg ($value)";
    }
}

sub elemOf($self, @elems) {
    return sub($value, @) {
        return (grep { $_ eq $value } @elems) ? undef
            : 'expected a value from the list: ' . join(', ', @elems);
    }
}

sub bool($self, @extraElems) {
    return $self->elemOf(qw(true false on off yes no 1 0), @extraElems);
}

sub numRange($self, $min, $max) {
    return sub($num, @) {
        return "'$num' is not numeric" if !$numeric->($num);
        return $num >= $min && $num <= $max ? undef : "'$num' is out of range (expected $min-$max)";
    }
}

sub ipv4($self) {
    return $self->regexp(qr/^$IPv4_re$/, 'not a valid IPv4 address');
}

sub ipv6($self) {
    return $self->regexp(qr/^$IPv6_re$/, 'not a valid IPv6 address');
}

sub ip($self) {
    return $self->regexp(qr/^(?:$IPv4_re|$IPv6_re)$/, 'not a valid IP address');
}

sub cidrv4($self) {
    return $self->regexp(qr!^$IPv4_re/\d{1,2}$!, 'not a valid IPv4 CIDR address');
}

sub cidrv6($self) {
    return $self->regexp(qr!^$IPv6_re/\d{1,3}$!, 'not a valid IPv6 CIDR address');
}

sub cidr($self) {
    return $self->regexp(qr!^(?:$IPv4_re/\d{1,2}|$IPv6_re/\d{1,3})$!, 'not a valid CIDR address');
}

sub lxIP($self) {
    return sub($ip, @) {
        return undef if $ip eq 'dhcp' || $ip eq 'addrconf';

        return $self->cidr->($ip);
    }
}

sub vlanId($self) {
    return sub($vlan, @) {
        return "vlan-id '$vlan' is not numeric" if !$numeric->($vlan);
        return $vlan > 0 && $vlan < 4095 ? undef : "vlan-id '$vlan' is out of range";
    }
}

sub macaddr($self) {
    return $self->regexp(qr/^(?:[\da-f]{1,2}:){5}[\da-f]{1,2}$/i, 'not a valid MAC address');
}

sub file($self, $op, $msg) {
    return sub($file, @) {
        return open (my $fh, $op, $file) ? undef : "$msg $file: $!";
    }
}

sub globalNic($self) {
    return sub($nic, $net) {
        return $net->{'allowed-address'} ? undef : 'allowed-address must be set when global-nic is auto'
            if $nic eq 'auto';

        return (grep { $_ eq $nic } @{$self->utils->getOverLink}) ? undef
            : "link '$nic' does not exist or is wrong type";
    }
}

sub zoneNic($self) {
    return sub($name, $nic) {
        # if global-nic is set we just check if the vnic name is valid
        return $name =~ /^\w+\d+$/ ? undef : 'not a valid vnic name'
            if $nic->{'global-nic'};

        # physical links are ok
        my $dladm = $self->utils->readProc('dladm', [ qw(show-phys -p -o link) ]);
        return undef if grep { $_ eq $name } @$dladm;

        $dladm = $self->utils->readProc('dladm', [ (qw(show-vnic -p -o), join (',', @VNICATTR)) ]);

        for my $vnic (@$dladm) {
            my @vnicattr = split /:/, $vnic, scalar @VNICATTR;
            my %nicProps = map { $_ => $vnicattr[$self->vnicmap->{$_}] } @VNICATTR;
            next if $nicProps{link} ne $name;

            $nic->{over} && $nic->{over} ne $nicProps{over}
                && $self->log->warn("WARNING: vnic specified over '" . $nic->{over}
                    . "' but is over '" . $nicProps{over} . "'\n");

            delete $nic->{over};
            return undef;
        }

        # only reach here if vnic does not exist
        # get first global link if over is not given

        $nic->{over} = $self->utils->getOverLink->[0] if !exists $nic->{over};

        local $@;
        eval {
            local $SIG{__DIE__};

            privSet({ add => 1, inherit => 1 }, PRIV_SYS_DL_CONFIG);
            $self->utils->exec('dladm', [ (qw(create-vnic -l), $nic->{over}, $name) ]);
            privSet({ remove => 1, inherit => 1 }, PRIV_SYS_DL_CONFIG);
        };
        return $@ if $@;

        delete $nic->{over};
        return undef;
    }
}

sub vcpus($self) {
    return sub($vcpu, @) {
        return undef if $numeric->($vcpu);

        my @vcpu = split /,/, $vcpu;

        shift @vcpu if $numeric->($vcpu[0]);

        for my $vcpuConf (@vcpu){
            my @vcpuConf = split /=/, $vcpuConf, 2;
            exists $vcpuOptions{$vcpuConf[0]} && $numeric->($vcpuConf[1])
                or return "ERROR: vcpu setting not valid";
        }

        return undef;
    }
}

sub fileOrZvol($self) {
    return sub($path, $disk) {
        $path =~ s|^/dev/zvol/r?dsk/||;

        my $f = Mojo::File->new($path);
        if ($f->is_abs) {
            return undef if -f $f;
            return "file '$f' does not exist, did you mean to configure a zvol?";
        }

        if (!-e "/dev/zvol/rdsk/$path") {
            # TODO: need to re-validate blocksize, size and sparse here
            # although we could specify the validation order we cannot check whether
            # the validators succeeded or failed
            # returning undef (i.e. successful validation) as the properties
            # validator will return a specific error message already, but don't create a volume
            return undef if $disk->{blocksize} && $self->blockSize->($disk->{blocksize})
                || $disk->{size} && $self->regexp(qr/^\d+[bkmgtpe]$/i)->($disk->{size})
                || $disk->{sparse} && $self->bool->($disk->{sparse});

            my @cmd = (qw(create -p),
                ($self->utils->boolIsTrue($disk->{sparse}) ? qw(-s) : ()),
                ($disk->{blocksize} ? ('-o', "volblocksize=$disk->{blocksize}") : ()),
                '-V', ($disk->{size} // '10G'), $path);

            local $@;
            eval {
                local $SIG{__DIE__};

                # prevent parent dataset ending up with a temporary setuid property set to 'off'
                privSet({ all => 1 });
                $self->utils->exec('zfs', \@cmd);
                privSet({ reset => 1 });
            };

            return $@ if $@;
        }
        else {
            my $props = $self->utils->getZfsProp($path, [ qw(volsize volblocksize refreservation) ]);

            $self->log->warn("WARNING: block size cannot be changed for existing disk '$path'")
                if $disk->{blocksize} && $toBytes->($disk->{blocksize}) != $toBytes->($props->{volblocksize});
            $self->log->warn("WARNING: sparse attribute cannot be changed for existing disk '$path'")
                if $props->{refreservation} eq 'none' && !$self->utils->boolIsTrue($disk->{sparse})
                    || $props->{refreservation} ne 'none' && $self->utils->boolIsTrue($disk->{sparse});

            # if size is not set we'll keep the current zvol size
            return undef if !$disk->{size};

            my $diskSize    = $toBytes->($props->{volsize});
            my $newDiskSize = $toBytes->($disk->{size});

            if ($newDiskSize && $diskSize > $newDiskSize) {
                $self->log->warn("WARNING: cannot shrink disk '$path'");
            }
            elsif ($newDiskSize > $diskSize) {
                $self->log->debug("enlarging disk '$path' to $disk->{size}");

                privSet({ add => 1, inherit => 1 }, PRIV_SYS_MOUNT);
                $self->utils->exec('zfs', [ 'set', "volsize=$disk->{size}", $path ]);
                privSet({ remove => 1, inherit => 1 }, PRIV_SYS_MOUNT);
            }
        }

        return undef;
    }
}

sub zonePath($self) {
    return sub($path, @) {
        my $parent = dirname $path;

        return undef if $self->utils->getMntDs($parent);
        return "could not find parent dataset for '$path'. Make sure that '$parent' is a ZFS dataset";
    }
}

sub absPath($self, $exists = 1) {
    return sub($path, @) {
        my $f = Mojo::File->new($path);

        return "$path is not an absolute path" if !$f->is_abs;
        return "$path does not exist" if $exists && !-e $f;
        return undef;
    }
}

sub blockSize($self) {
    return sub($blksize, @) {
        return $checkBlockSize->($blksize, 'blocksize', '512', '128k');
    }
}

sub sectorSize($self) {
    return sub($secSize, @) {
        my ($logical, $physical) = $secSize =~ m!^([^/]+)(?:/([^/]+))?$!;

        # logical size must be provided
        my $check = $checkBlockSize->($logical, 'sectorsize (logical)', '512', '16k');
        return $check if $check;

        if ($physical) {
            $check = $checkBlockSize->($physical, 'sectorsize (physical)', '512', '16k');
            return $check if $check;

            return "logical sectorsize ($logical) must be less or equal than physical ($physical)"
                if $logical > $physical;
        }

        return undef;
    }
}

sub bootrom($self) {
    return sub($bootrom, @) {
        return undef if !$self->absPath(0)->($bootrom);
        return $self->elemOf(
            grep { !/^BHYVE_VARS$/ }
            map { basename($_, '.fd') }
            glob "$FWPATH/*.fd"
        )->($bootrom);
    }
}

sub bhyveBootDev($self) {
    return sub($bootdev, @) {
        for ($bootdev) {
            /^(?:cd|dc)$/ && last;
            /^shell$/ && last;
            /^path\d*$/ && last;
            /^bootdisk$/ && last;
            /^disk\d*$/ && last;
            /^cdrom\d*$/ && last;
            /^net\d*(?:=(?:pxe|http))?$/ && last;
            /^boot\d+$/ && last;

            return "boot device '$_' is not valid";
        }

        return undef;
    }
}

sub stripDev($self) {
    return sub($path, @) {
        $path =~ s|^/dev/zvol/r?dsk/||;
        # resources don't like multiple forward slashes, remove them
        $path =~ s|/{2,}|/|g;

        return $path;
    }
}

sub toInt($self) {
    return sub($value, @) {
        return $value if !$value;

        $value =~ s/\.\d+//;

        return $value;
    }
}

sub toBytes($self) {
    return sub($value, @) {
        return $value if !$value;

        return join '/', map { my $val = $_; $toBytes->($val) || $val } split m!/!, $value;
    }
}

sub toHash($self, $attr, $isarray = 0) {
    return sub($value, @) {
        my $elems = $isarray ? $self->toArray->($value) : $value;

        return $self->utils->isArrRef($elems)
            ? [ map { $toHash->($attr, $_) } @$elems ]
            : $toHash->($attr, $elems);
    }
}

sub toArray($self, $split = '') {
    return sub($elem, @) {
        return $self->utils->isArrRef($elem) ? $elem : [ $split ? split (/$split/, $elem) : $elem ];
    }
}

sub toPWHash($self) {
    return sub($str, @) {
        return $str if $self->utils->isPWHash($str) || Mojo::File->new($str)->is_abs;

        my $rng  = Bytes::Random::Secure::Tiny->new;
        my $seed = b64_encode($rng->bytes(12)); # gives 16 bytes
        $seed =~ s/\+/./g;

        return crypt ($str, "\$6\$$seed");
    }
}

sub toVNCHash($self) {
    return sub($attr, @) {
        return {} if !$attr;
        return $attr if $self->utils->isHashRef($attr);

        return {
            map {
                my ($key, $val) = split /=/, $_, 2;

                if ($key =~ /^(?:on|off)$/) {
                    $val = $key;
                    $key = 'enabled';
                }

                $key => $val // 'on'
            } split /,/, $attr
        };
    }
}

sub kvmVNC($self) {
    return sub($vnc, @) {
        return undef if $vnc =~ m!(?:^|,)unix[:=]/!;
        return $self->bool->($vnc);
    }
}

sub ppt($self) {
    return $self->regexp(qr/^ppt\d+/, 'expected a ppt device') if $ENV{__ZADMTEST};

    return sub($dev, @) {
        my $ppts = decode_json join ' ', @{$self->utils->readProc('pptadm', [ qw(list -aj) ])};

        return "ppt device '$dev' does not exist"
            if !$self->utils->isArrRef($ppts->{devices})
                || !grep { $_->{dev} eq "/dev/$dev" } @{$ppts->{devices}};

        return undef;
    }
}

sub hostbridge($self) {
    return sub($hb, @) {
        return undef if $hb =~ /^vendor=(?:0x[[:xdigit:]]+|\d+),device=(?:0x[[:xdigit:]]+|\d+)$/i;
        return $self->elemOf(qw(i440fx q35 amd netapp none))->($hb);
    }
}

sub cloudinit($self) {
    return sub($ci, @) {
        return undef if $ci =~ m!^https?://!;
        return $self->file('<', 'No such file,')->($ci) if Mojo::File->new($ci)->is_abs;
        return 'Expected a URL, file path, on or off' if $self->bool->($ci);
        return undef;
    }
}

sub qemuCPUtype($self) {
    return sub($cpuType, @) {
        my $cpuTypes = $self->utils->readProc('qemu', [ qw(-cpu ?) ]);
        s/^x86\s+\[?|\]$//g for @$cpuTypes;

        my $cpuFeatures = $self->utils->readProc('isainfo', [ qw(-x) ]);
        my ($featStr) = map { /^amd64:\s+(.+)$/ } @$cpuFeatures;
        my @features = map { "+$_" } split /\s+/, $featStr;

        my @cpuType = split /,/, $cpuType;

        my $typeInvalid = $self->elemOf(@$cpuTypes)->(shift @cpuType);
        return $typeInvalid if length ($typeInvalid);

        for my $feature (@cpuType) {
            my $featureInvalid = $self->elemOf(@features)->($feature);

            return $featureInvalid if length ($featureInvalid);
        }

        return undef;
    }
}

sub stringorfile($self) {
    return sub($arg, @) {
        return $self->file('<', 'No such file,')->($arg) if Mojo::File->new($arg)->is_abs;
        return $self->regexp(qr/^.*$/, 'Expected a string')->($arg);
    }
}

sub noVNC($self) {
    return sub($path, @) {
        return undef if -r Mojo::File->new($path, 'vnc.html');
        return "noVNC not found under '$path'";
    }
}

1;

__END__

=head1 COPYRIGHT

Copyright 2023 OmniOS Community Edition (OmniOSce) Association.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.
This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Dominik Hassler E<lt>hadfl@omnios.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
