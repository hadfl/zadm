package Zadm::Zone::base;
use Mojo::Base -base, -signatures;

use Mojo::File;
use Mojo::Log;
use Mojo::Home;
use Mojo::IOLoop::Subprocess;
use Mojo::Loader qw(load_class);
use Mojo::Promise;
use Mojo::Util qw(class_to_path);
use Data::Processor;
use Pod::Text;
use Pod::Usage;
use Storable qw(dclone freeze);
use Term::ANSIColor qw(colored);
use Zadm::Privilege qw(:CONSTANTS privSet);
use Zadm::Utils;
use Zadm::Validator;
use Zadm::Zones;

# constants/definitions
has statemap   => sub {
    {
        boot        => [ qw(installed) ],
        shutdown    => [ qw(running) ],
        halt        => [ qw(running) ],
        install     => [ qw(configured) ],
        uninstall   => [ qw(incomplete installed) ],
    }
};
# TODO: properties that can only be set on creation/needs verification
has createprop => sub { [ qw(zonename zonepath brand ip-type) ] };
has template   => sub($self) {
    my $name = $self->name;

    return {
        zonename    => $name,
        zonepath    => ($ENV{__ZADM_ALTROOT} // '') . "/zones/$name",
        brand       => $self->brand,
        'ip-type'   => 'exclusive',
        autoboot    => 'false',
        net         => [{
            physical     => "${name}0",
            'global-nic' => $self->utils->getOverLink->[0],
        }],
        %{$self->utils->domain},
        %{$self->utils->scheduler},
    }
};
has options => sub {
    {
        fw => {
            edit   => {
                getopt => 'edit|e=s',
            },
            map {
                $_ => { getopt =>  "$_|" . substr $_, 0, 1 }
            } qw(reload disable monitor top)
        },
    }
};

# private methods
my $resIsArray = sub($self, $res) {
    return exists $self->schema->{$res} && $self->schema->{$res}->{array};
};

my $resIsAttr = sub($self, $res) {
    return exists $self->schema->{$res} && $self->schema->{$res}->{'x-attr'};
};

my $propIsArray = sub($self, $res, $prop) {
    return exists $self->schema->{$res}->{members}->{$prop}
        && $self->schema->{$res}->{members}->{$prop}->{array};
};

my $propIsHash = sub($self, $res, $prop) {
    return exists $self->schema->{$res}->{members}->{$prop}
        && exists $self->schema->{$res}->{members}->{$prop}->{members};
};

my $getArray = sub($self, $val) {
    # remove leading and trailing square brackets
    $val =~ s/^\s*\[// && $val =~ s/\]\s*$//;

    return [ split /,/, $val ];
};

my $setArray = sub($self, $val) {
    return join (',', @$val);
};

my $getHash = sub($self, $val) {
    # remove leading and trailing brackets
    $val =~ s/^\s*\(// && $val =~ s/\)\s*$//;

    return { split /[,=]/, $val };
};

my $setHash = sub($self, $val) {
    return '(' . join (',', map { "$_=$val->{$_}" } keys %$val) . ')';
};

my $getVal = sub($self, $res, $prop, $val) {
    # remove leading and trailing quotes
    $val =~ s/^\s*"// && $val =~ s/"\s*$//;

    return $self->$propIsArray($res, $prop) ? $self->$getArray($val)
         : $self->$propIsHash($res, $prop)  ? $self->$getHash($val)
         :                                    $val;
};

my $setVal = sub($self, $prop) {
    return $self->utils->isArrRef($prop)  ? $self->$setArray($prop)
         : $self->utils->isHashRef($prop) ? $self->$setHash($prop)
         :                                  $prop;
};

my $isRes = sub($self, $prop) {
    return exists $self->resmap->{$prop};
};

my $isResProp = sub($self, $res, $prop) {
    return exists $self->schema->{$res}->{members}->{$prop};
};

my $isProp = sub($self, $prop) {
    return exists $self->schema->{$prop};
};

my $delResource = sub($self, $res) {
    my $name = $self->name;
    my @cmd  = ('-z', $name, qw(remove -F), $res);

    $self->utils->exec('zonecfg', \@cmd, "cannot delete resource '$res' from zone '$name'");

    delete $self->attrs->{$res};
};

my $setProperty = sub($self, $cfg, $prop) {
    my $name = $self->name;

    my @cmd = ('-z', $name, 'set', $prop, '=',
        q{"} . $self->$setVal($cfg->{$prop}) . q{"});

    $self->utils->exec('zonecfg', \@cmd, "cannot set property '$prop'");

    $self->attrs->{$prop} = $cfg->{$prop};
};

my $decodeProp = sub($self, $res, $prop, $val) {
    my ($_prop, $_val) = $val =~ /name=([^,]+),value="([^"]+)"/;

    return ($_prop, $_val) if $res eq 'net' && $prop eq 'property' && $_prop;

    return ($prop, $val);
};

my $encodeProp = sub($self, $res, $prop, $val) {
    return ('set', $prop, '=', q{"} . $self->$setVal($val) . q{"}, ';')
        if ($res ne 'net' || (exists $self->schema->{$res}->{members}->{$prop}
            && !$self->schema->{$res}->{members}->{$prop}->{'x-netprop'}));

    $val = $self->utils->isArrRef($val) ? qq{(name=$prop,value="} . join (',', @$val) . '")'
         : qq{(name=$prop,value="$val")};

    return (qw(add property), $val, ';');
};

my $clearProperty = sub($self, $prop) {
    my $name = $self->name;

    my @cmd = ('-z', $name, 'clear', $prop);

    $self->utils->exec('zonecfg', \@cmd, "cannot clear property $prop");

    delete $self->attrs->{$prop};
};

my $clearAttributes = sub($self, $cfg) {
    # TODO: adding support for rctls (for now just aliased rctls are supported)
    for my $attr (keys %{$self->attrs}) {
        next if $attr eq 'rctl';

        # simple attributes
        if (!$self->$isRes($attr)) {
            delete $cfg->{$attr} if $self->schema->{$attr}->{'x-noempty'}
                && !length ($cfg->{$attr}) && length ($self->attrs->{$attr});

            $self->$clearProperty($attr) if !exists $cfg->{$attr};

            next;
        }

        # resources
        if (!$cfg->{$attr} || freeze($cfg->{$attr}) ne $self->attrs->{$attr}) {
            $self->$delResource($attr);
        }
        else {
            delete $cfg->{$attr};
        }
    }
};

my $getConfig = sub($self) {
    my $config = {};

    return {} if !$self->zones->exists($self->name);

    my $props = $self->utils->readProc('zonecfg', ['-z', $self->name, 'info']);

    my $res;
    for my $line (@$props) {
        # remove square brackets at beginning and end of line
        $line =~ s/^(\s*)\[/$1/ && $line =~ s/\]\s*//;
        # drop lines ending with 'not specified'
        next if $line =~ /not\s+specified$/;
        my ($isres, $prop, $val) = $line =~ /^(\s*)([^:\s]+):(?:\s+(.*))?$/;
        # at least property must be valid
        length ($prop) || do {
            $self->log->warn("could not decode '$line'");
            next;
        };
        if (length $isres) {
            # decode property
            ($prop, $val) = $self->$decodeProp($res, $prop, $val);
            # check if property exists in schema
            $self->log->warn("'$prop' is not a member of resource '$res'")
                if !$self->$isResProp($res, $prop);
            if ($self->$resIsArray($res)) {
                $config->{$res}->[-1]->{$prop} = $self->$getVal($res, $prop, $val);
            }
            else {
                $config->{$res}->{$prop} = $self->$getVal($res, $prop, $val);
            }
        }
        else {
            # check if property exists in schema
            $self->$isProp($prop) || do {
                $self->log->warn("$prop does not exist in schema");
                next;
            };
            # check if property is a resource
            $self->$isRes($prop) && do {
                $res = $prop;
                push @{$config->{$prop}}, {}
                    if $self->$resIsArray($prop);

                next;
            };
            $config->{$prop} = $val;
        }
    }
    $self->attrs({
        map {
            $_ => ref $config->{$_} ? freeze($config->{$_}) : $config->{$_}
        } keys %$config
    }) if !%{$self->attrs};

    return $self->getPostProcess($config);
};

my $zoneCmd = sub($self, $cmd, $opts = [], $fork = 0) {
    my $name = $self->name;

    $self->statemap->{$cmd} && !(grep { $self->is($_) } @{$self->statemap->{$cmd}}) && do {
        $self->log->warn("WARNING: cannot '$cmd' $name. "
            . "$name is " . $self->state . ' and '
            . 'not ' . join (' or ', @{$self->statemap->{$cmd}}) . '.');
        return 0;
    };

    privSet({ all => 1 });
    $self->utils->exec('zoneadm', [ '-z', $name, $cmd, @$opts ],
        "cannot $cmd zone $name", $fork);
    privSet({ reset => 1 });
};

my $getClassPath = sub($self, $mod) {
    return Mojo::File->new($self->home, 'lib', class_to_path($mod))->to_abs->to_string;
};

# private static methods
# not using pod_write from Data::Processor as we want a different formatting
my $genDoc;
$genDoc = sub($schema, $over = 0) {
    my @doc;
    for my $attr (sort {
        # mandatory attributes first
        ($schema->{$a}->{optional} // 0) <=> ($schema->{$b}->{optional} // 0)
        ||
        $a cmp $b
    } keys %$schema) {
        my $str = $attr;
        $str .= ' (optional)' if $schema->{$attr}->{optional};
        $str .= ':';
        $str .= ' array of' if $schema->{$attr}->{array};
        $str .= exists $schema->{$attr}->{members}
            ? ' resource containing the following attributes:'
            : ' ' . ($schema->{$attr}->{description} || '<description missing>');

        push @doc, $over ? "  $str" : ($str, '');

        if (exists $schema->{$attr}->{members}) {
            push @doc, ('', '=over', '');
            push @doc, @{$genDoc->($schema->{$attr}->{members}, 1)};
            push @doc, ('', '=back', '');
        }
    }

    return \@doc;
};

# attributes
has log     => sub { Mojo::Log->new(level => 'debug') };
has zones   => sub($self) { Zadm::Zones->new(log => $self->log) };
has utils   => sub($self) { Zadm::Utils->new(log => $self->log) };
has sv      => sub($self) { Zadm::Validator->new(log => $self->log) };
has dp      => sub($self) { Data::Processor->new($self->schema) };
has name    => sub { Mojo::Exception->throw("ERROR: zone name must be specified on instantiation.\n") };
# attribute to keep track of currently saved attributes in zonecfg
has attrs   => sub { {} };
has brand   => sub($self) { lc ((split /::/, ref $self)[-1]) };
has ibrand  => sub($self) { $self->brand };
has public  => sub { [ qw(login fw) ] };
has opts    => sub { {} };
has mod     => sub($self) { ref $self };
has smod    => sub($self) { my $mod = $self->mod; $mod =~ s/Zone/Schema/; $mod };
has home    => sub($self) { Mojo::Home->new->detect($self->mod) };
has exists  => sub($self) { $self->zones->exists($self->name) };
has hasimg  => sub($self) { return $self->opts->{image} };
has image   => sub($self) {
    Mojo::Exception->throw("ERROR: image option has not been provided\n") if !$self->hasimg;
    return $self->zones->images->image($self->opts->{image}, $self->ibrand, { brand => $self->brand });
};

has logfile => sub($self) {
    my $zlog = $self->config->{zonepath} . '/root/tmp/init.log';
    return -r $zlog ? $zlog : $self->config->{zonepath} . '/log/zone.log';
};

has rootds  => sub($self) { $self->utils->getMntDs($self->config->{zonepath}) };
has snappf  => sub($self) { $self->utils->gconf->{SNAPSHOT}->{prefix} // 'zadm__' };
has beaware => 1;

has config  => sub($self) {
    return $self->$getConfig if $self->exists;

    return {
        %{$self->template},
        zonename => $self->name,
        brand    => $self->brand,
    }
};

has schema  => sub($self) {
    my $smod = $self->smod;
    my $modf = $self->$getClassPath($smod);

    # fall back to generic schema if there is no brand specific
    -e $modf || do {
        $smod = __PACKAGE__;
        $smod =~ s/Zone/Schema/;
    };

    load_class($smod)
        and Mojo::Exception->throw("ERROR: cannot load schema class '$smod'.\n");

    return $smod->new(sv => $self->sv)->schema;
};

has resmap => sub($self) {
    return $self->utils->genmap(
        [ grep { exists $self->schema->{$_}->{members} } keys %{$self->schema} ]
    );
};

has createpropmap => sub($self) {
    return $self->utils->genmap($self->createprop);
};

# constructor
sub new($class, @args) {
    # using Storable which is in core for a deep compare
    # make sure the hash keys are sorted for serialisation
    $Storable::canonical = 1;

    return $class->SUPER::new(@args);
}

# public methods
sub addResource($self, $res, $props) {
    my $name = $self->name;
    my @cmd  = ('-z', $name, 'add', $res, ';');

    push @cmd, $self->$encodeProp($res, $_, $props->{$_}) for keys %$props;

    push @cmd, qw(end);

    $self->utils->exec('zonecfg', \@cmd, "cannot config zone $name");

    $self->attrs->{$res} = freeze($props);
}

sub getPostProcess($self, $cfg) {
    my $schema = $self->schema;

    for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
        my $name = $cfg->{attr}->[$i]->{name};

        next if !$self->$resIsAttr($name);

        $cfg->{$name} = exists $schema->{$name} && $schema->{$name}->{array}
                      ? [ split /,/, $cfg->{attr}->[$i]->{value} ]
                      : $cfg->{attr}->[$i]->{value};

        splice @{$cfg->{attr}}, $i, 1;
    }
    # check if attr is empty. if so remove it
    delete $cfg->{attr} if !@{$cfg->{attr}};

    # TODO: adding support for rctls (for now just aliased rctls are supported)
    delete $cfg->{rctl};

    return $cfg;
}

sub setPreProcess($self, $cfg) {
    # remove empty arrays and add remaining attr resources
    for my $res (keys %$cfg) {
        if ($self->utils->isArrRef($cfg->{$res}) && !@{$cfg->{$res}}) {
            delete $cfg->{$res};

            next;
        }

        next if !$self->$resIsAttr($res);

        my %elem = (
            name => $res,
            type => 'string',
        );

        $elem{value} = $self->utils->isArrRef($cfg->{$res})
                     ? join (',', @{$cfg->{$res}})
                     : $cfg->{$res};

        push @{$cfg->{attr}}, \%elem;
        delete $cfg->{$res};
    }

    # sort the attr resources by name for deep compare
    $cfg->{attr} = [ sort { $a->{name} cmp $b->{name} } @{$cfg->{attr}} ]
        if $self->utils->isArrRef($cfg->{attr});

    return $cfg;
}

sub validate($self, $config = $self->config) {
    my $ec = $self->dp->validate($config);
    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}) . "\n");

    return 1;
}

sub setConfig($self, $config) {
    # validate new config
    $self->validate($config);

    # we don't support brand changes
    Mojo::Exception->throw("ERROR: brand cannot be changed from '"
        . $self->config->{brand} . "' to '" . $config->{brand} . ".\n")
        if $self->config->{brand} ne $config->{brand};

    # set new config and create a copy for pre-processing
    $self->config($config);
    $self->setPreProcess(my $cfg = dclone $config);

    # clean up all existing resources and
    # simple attributes which have been removed
    $self->$clearAttributes($cfg);

    $self->create({ map { $_ => $cfg->{$_} } @{$self->createprop} })
        if !$self->exists;

    my $installed = !$self->is('configured');
    for my $prop (keys %{$cfg}) {
        $self->log->debug("processing property '$prop'");

        # skip props that cannot be changed once the zone is installed
        next if $installed && exists $self->createpropmap->{$prop};

        if ($self->utils->isArrRef($cfg->{$prop})) {
            $self->log->debug("property '$prop' is a resource array");

            $self->addResource($prop, $_) for @{$cfg->{$prop}};
        }
        elsif ($self->$isRes($prop)) {
            $self->log->debug("property '$prop' is a resource");

            $self->addResource($prop, $cfg->{$prop});
        }
        else {
            next if defined $self->attrs->{$prop} && $self->attrs->{$prop} eq $cfg->{$prop}
                || $self->schema->{$prop}->{'x-noempty'} && !length ($cfg->{$prop});

            $self->log->debug("property '$prop' changed:",
                ($self->attrs->{$prop} // '(none)'), '->', $cfg->{$prop});

            $self->$setProperty($cfg, $prop);
        }
    }

    return 1;
}

sub getOptions($self, $oper) {
    return [] if !exists $self->options->{$oper};

    return [ map { $self->options->{$oper}->{$_}->{getopt} } keys %{$self->options->{$oper}} ];
}

sub checkMandOptions($self, $oper) {
    $self->options->{$oper}->{$_}->{mand} && !$self->opts->{$_}
        and return 0 for keys %{$self->options->{$oper}};

    return 1;
}

sub gconfIs($self, $sect, $elem, $val) {
    return $self->utils->gconf->{$sect}->{$elem}
        && $self->utils->gconf->{$sect}->{$elem} eq $val;
}

sub state($self) {
    $self->zones->refresh;
    my $zones = $self->zones->list;

    return exists $zones->{$self->name} ? $zones->{$self->name}->{state} : 'unknown';
}

sub is($self, $state = '') {
    return $self->state eq $state;
}

sub isPublic($self, $method) {
    return !!grep { $_ eq $method } @{$self->public};
}

sub isSimpleProp($self, $prop) {
    $self->$isProp($prop)
        or Mojo::Exception->throw("ERROR: property '$prop' does not exist for brand " . $self->brand . "\n");

    return $self->schema->{$prop}->{'x-simple'}
        || !$self->$isRes($prop) && !$self->$resIsArray($prop)
}

sub boot($self, $cOpts) {
    $self->opts->{console} = 1 if $self->gconfIs(qw(CONSOLE auto_connect on));
    # fork boot to the bg if we are about to attach to the console
    $self->$zoneCmd('boot', [], $self->opts->{console});

    $self->console($cOpts) if $self->opts->{console};
}

sub shutdown($self, $cOpts) {
    # fork shutdown to the bg
    $self->$zoneCmd('shutdown', [], 1);

    $self->console($cOpts) if $self->opts->{console};
}

sub reboot($self, $cOpts) {
    # fork shutdown to the bg
    $self->$zoneCmd('shutdown', [ qw(-r) ], 1);

    $self->console($cOpts, 1) if $self->opts->{console};
}

sub poweroff($self) {
    $self->$zoneCmd('halt');
}

sub reset($self, $cOpts) {
    $self->poweroff;
    $self->boot($cOpts);
}

sub login($self) {
    my $name = $self->name;

    Mojo::Exception->throw("ERROR: '$name' is not running, cannot log in.\n")
        if !$self->is('running');

    privSet({ all => 1, inherit => 1 });
    $self->utils->exec('zlogin', [ $name ], "cannot log in to $name");
    privSet({ reset => 1, inherit => 1 });
}

sub console($self, $cOpts = [], $reboot = 0) {
    my $name = $self->name;

    push @$cOpts, qw(-d) if $self->gconfIs(qw(CONSOLE auto_disconnect on))
        && !$reboot && !grep { $_ eq '-d' } @$cOpts;
    push @$cOpts, '-e', $self->utils->gconf->{CONSOLE}->{escape_char}
        if $self->utils->gconf->{CONSOLE}->{escape_char} && !grep { /^-e.?$/ } @$cOpts;

    privSet({ all => 1 });
    $self->utils->exec('zlogin', [ '-C', @$cOpts, $name ],
        "cannot attach to $name zone console");
    privSet({ reset => 1 });
}

sub create($self, $props) {
    my @cmd = ('-z', $self->name, qw(create -b ;));
    push @cmd, ('set', $_, '=', q{"} . $props->{$_} . q{"}, ';')
        for keys %$props;

    $self->utils->exec('zonecfg', \@cmd);
}

sub delete($self) {
    $self->utils->exec('zonecfg', [
        '-z', $self->name, 'delete', $self->opts->{force} ? qw(-F) : ()
    ]);
}

sub install($self, @args) {
    # TODO centralise and improve this
    $ENV{__ZADM_ALTROOT} && do {
        $self->log->warn('Cannot install a zone inside an alternate root.');
        return 1;
    };
    $self->$zoneCmd('install', \@args);
}

sub uninstall($self) {
    # TODO centralise and improve this
    $ENV{__ZADM_ALTROOT} && do {
        $self->log->warn('Cannot uninstall a zone inside an alternate root.');
        return 1;
    };
    $self->$zoneCmd('uninstall', $self->opts->{force} ? [ qw(-F) ] : []);
}

sub remove($self) {
    my $name = $self->name;
    Mojo::Exception->throw("ERROR: cannot delete running zone '$name'\n")
        if $self->is('running');

    $self->state =~ /^(?:incomplete|installed)$/ && do {
        $self->log->debug("uninstalling zone '$name'");
        $self->uninstall;
    };
    $self->is('configured') && do {
        $self->log->debug("deleting zone '$name'");
        $self->delete;
    };
}

sub zStats($self, $raw = 0) {
    return {
        RAM    => $self->config->{'capped-memory'}->{physical} // '-',
        CPUS   => $self->config->{'capped-cpu'}->{ncpus} // '-',
        SHARES => $self->config->{'cpu-shares'} // '1',
    };
}

sub snapshot($self, $snapname, $opts) {
    my $snappf = $self->snappf;

    if (!$snapname) {
        my @snaps = grep { /^[^@]+\@\Q$snappf\E/ } @{$self->utils->snapshot('list', $self->rootds)};

        return say 'no zadm snapshots for ' . $self->name if !@snaps;

        my $format = "%-18s%6s   %s\n";
        my @props  = qw(used creation);
        my @header = (qw(NAME), map { uc } @props);

        printf $format, @header;

        Mojo::Promise->map(
            { concurrency => $self->utils->ncpus },
            sub($snap) {
                Mojo::IOLoop::Subprocess->new->run_p(sub {
                    $self->utils->getZfsProp($snap, \@props)
                });
            }, @snaps
        )->then(sub(@stats) {
            for my $i (0 .. $#snaps) {
                my ($name) = $snaps[$i] =~ /^[^@]+\@\Q$snappf\E([^@]+)$/;
                printf $format, $name, map { $stats[$i]->[0]->{$_} } @props;
            }
        })->wait;

        return 1;
    }

    if ($opts->{destroy}) {
        $self->utils->snapshot('destroy', $self->rootds, $self->snappf . $snapname);
        return say "snapshot $snapname destroyed for " . $self->name;
    }

    $self->utils->snapshot('snapshot', $self->rootds, $self->snappf . $snapname);
    say "snapshot $snapname created for " . $self->name;
}

sub rollback($self, $snapname, $opts) {
    return warn "WARNING: rollback is not supported on BE-aware brands.\n"
        if $self->beaware;

    $self->utils->snapshot('rollback', $self->rootds, $self->snappf . $snapname,
        $opts->{r} ? [ qw(-r) ] : []);
}

sub usage($self) {
    pod2usage(-input => $self->$getClassPath($self->mod), 1);
}

sub doc($self) {
    my $opts = $self->opts;

    my $schema;
    my $header;
    if ($opts->{attr}) {
        Mojo::Exception->throw("ERROR: attribute '" . $opts->{attr}
            . "' does not exist for brand '" . $self->brand . "'.\n")
            if !exists $self->schema->{$opts->{attr}};

        $schema = { $opts->{attr} => $self->schema->{$opts->{attr}} };
        $header = '=head1 ' . $self->brand . ' brand ' . $opts->{attr} . ' attribute';
    }
    else {
        $schema = $self->schema;
        $header = '=head1 ' . $self->brand . ' brand attributes';
    }

    my $pod = Pod::Text->new;

    $pod->parse_lines(
        $header,
        '',
        @{$genDoc->($schema)},
        undef
    );
}

sub fw($self) {
    my $name = $self->name;
    my $opts = $self->opts;

    if ($opts->{edit}) {
        $self->usage if $opts->{edit} !~ /^(?:ipf6?|ipnat)$/;

        my $f = Mojo::File->new($self->config->{zonepath}, 'etc', $opts->{edit} . '.conf');
        my $mtime = -f $f ? $f->stat->mtime : 0;

        local $@;
        eval {
            local $SIG{__DIE__};

            # create config directory if it does not yet exist
            $f->dirname->make_path({ mode => 0700 });
        };
        Mojo::Exception->throw("ERROR: cannot access/create '" . $f->dirname . "': $!\n") if $@;

        if ($self->utils->isaTTY) {
            $self->utils->exec('editor', [ $f ]);
        }
        else {
            # ipf requires a trailing newline
            $f->spew(join ("\n", @{$self->utils->getSTDIN}), "\n");
        }

        return if !-f $f || $mtime == $f->stat->mtime;
        $opts->{reload} = 1;
    }

    return if !$self->is('running');

    if ($opts->{disable}) {
        privSet({ add => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);
        $self->utils->exec('ipf', [ '-GD', $name ]);
        privSet({ remove => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);

        return;
    }

    if ($opts->{reload}) {
        $self->log->debug("reloading ipf/ipnat for zone '$name'...");

        # bracket the whole block rather than each call to ipf/ipnat individually
        privSet({ add => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);
        $self->utils->exec('ipf', [ '-GE', $name ]);

        my $f = Mojo::File->new($self->config->{zonepath}, 'etc', 'ipf.conf');
        $self->utils->exec('ipf', [ qw(-GFa -f), $f, $name ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipf');

        $f = $f->sibling('ipf6.conf');
        $self->utils->exec('ipf', [ qw(-6GFa -f), $f, $name ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipf6');

        $f = $f->sibling('ipnat.conf');
        $self->utils->exec('ipnat', [ qw(-CF -G), $name, '-f', $f ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipnat');

        $self->utils->exec('ipf', [ '-Gy', $name ]);
        privSet({ remove => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);

        return;
    }

    if ($opts->{monitor}) {
        privSet({ add => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);
        # ignore the return code of ipmon since ^C'ing it will return non-null
        $self->utils->exec('ipmon', [ '-aG', $name ], undef, undef, 1);
        privSet({ remove => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);

        return;
    }

    if ($opts->{top}) {
        privSet({ add => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);
        $self->utils->exec('ipfstat', [ '-tG', $name ]);
        privSet({ remove => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);

        return;
    }

    my %statemap = (
        'pass'  => colored('pass', 'green'),
        'block' => colored('block', 'red'),
    );
    my %ipfheaders = (
        '-iG'   => colored("==> inbound IPv4 ipf rules for $name:", 'ansi208'),
        '-i6G'  => colored("==> inbound IPv6 ipf rules for $name:", 'ansi208'),
        '-oG'   => colored("==> outbound IPv4 ipf rules for $name:", 'ansi208'),
        '-o6G'  => colored("==> outbound IPv6 ipf rules for $name:", 'ansi208'),
    );

    # bracket the whole block rather than each call to ipfstat/ipnat individually
    privSet({ add => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);
    for my $ipf (qw(-iG -i6G -oG -o6G)) {
        my $rules = $self->utils->readProc('ipfstat', [ $ipf, $name ]);
        next if !@$rules;

        print $ipfheaders{$ipf} . "\n";
        for my $line (@$rules) {
            $line =~ s/$_/$statemap{$_}/ for keys %statemap;

            print "$line\n";
        }
        print "\n";
    }

    my $rules = $self->utils->readProc('ipnat', [ '-lG', $name ]);
    privSet({ remove => 1, inherit => 1 }, PRIV_SYS_IP_CONFIG);

    my @rules;
    for my $rule (@$rules) {
        next if !$rule || $rule =~ /active\s+MAP/;
        last if $rule =~ /active\s+sessions/;

        push @rules, $rule;
    }
    return if !@rules;

    print colored("==> ipnat rules for $name:", 'ansi208') . "\n";
    print join "\n", @rules;
    print "\n";
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-t <template_path>] <zone_name>
    delete [-f] <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-f] <zone_name>
    uninstall [-f] <zone_name>
    show [zone_name [property[,property]...]]
    list [-H] [-F <format>] [-b <brand>] [-s <state>] [zone_name]
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    pull <image_uuid>
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop [-c [extra_args]] <zone_name>
    restart [-c [extra_args]] <zone_name>
    poweroff <zone_name>
    reset [-c [extra_args]] <zone_name>
    console [extra_args] <zone_name>
    log <zone_name>
    fw [-r] [-d] [-t] [-m] [-e ipf|ipf6|ipnat] <zone_name>
    snapshot [-d] <zone_name> [<snapname>]
    rollback [-r] <zone_name> <snapname>
    help [-b <brand>]
    doc [-b <brand>] [-a <attribute>]
    man
    version

=head1 COPYRIGHT

Copyright 2022 OmniOS Community Edition (OmniOSce) Association.

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
