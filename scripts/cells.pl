#!/usr/bin/perl
# cells.pl -- who claims which map cell, and where is there room left.
#
# Maps sharing a lots= chain share one coordinate space, and IsoLot.MapFiles
# is an ordered list: on a collision the first entry wins and the loser's
# cell is discarded with no warning. Maps in different groups are separate
# worlds and cannot collide however much their coordinates overlap -- which
# is why the vanilla challenge maps sitting on 0,0 are not a problem.
#
# The grouping identity is the map DIRECTORY name, not title=; see
# MapGroups.findGroupWithAnyOfTheseDirectories.
#
#   perl Docs/cells.pl                     # tally, grouped
#   perl Docs/cells.pl --find 2x1          # free homes for a 2x1 map
#   perl Docs/cells.pl --grid              # ascii occupancy
#   PZ=/path/to/ProjectZomboid perl Docs/cells.pl extra/map/dir
use strict;
use warnings;

my $CELL = 256;                      # B42: IsoCell.CELL_SIZE_IN_SQUARES

my ($findw, $findh, $grid) = (0, 0, 0);
my @extra;
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '--find') {
        my $s = shift @ARGV // '';
        ($findw, $findh) = $s =~ /^(\d+)x(\d+)$/
            or die "--find wants WxH, e.g. --find 2x1\n";
    } elsif ($a eq '--grid') { $grid = 1 }
    else { push @extra, $a }
}

my @roots;
if (my $pz = $ENV{PZ}) { push @roots, "$pz/media/maps" }
else {
    for my $c ('/d/Steam', '/c/Program Files (x86)/Steam',
               '/c/SteamLibrary', '/d/SteamLibrary', '/e/SteamLibrary') {
        my $p = "$c/steamapps/common/ProjectZomboid/media/maps";
        push(@roots, $p), last if -d $p;
    }
}
my $home = $ENV{HOME} // $ENV{USERPROFILE} // '';
for my $d ("$home/Zomboid/mods", "$home/Zomboid/Workshop") { push @roots, $d if -d $d }
push @roots, @extra;

# --- collect ------------------------------------------------------------
my %maps;                             # directory path => record
for my $root (@roots) {
    open(my $fh, '-|', 'find', $root, '-name', '*.lotheader') or next;
    while (my $f = <$fh>) {
        chomp $f;
        my ($dir, $base) = $f =~ m{^(.*)/([^/]+)\.lotheader$} or next;
        my ($x, $y) = $base =~ /^(\d+)_(\d+)$/ or next;   # skip 300x300 names
        my $m = $maps{$dir} ||= do {
            my ($id) = $dir =~ m{([^/]+)$};
            my $label = $dir;
            $label =~ s{^.*/mods/}{} or $label =~ s{^.*/media/maps/}{};
            $label =~ s{/common/media/maps/}{ / };
            { id => $id, label => $label, cells => 0, at => {},
              minx => $x, maxx => $x, miny => $y, maxy => $y };
        };
        $m->{cells}++;  $m->{at}{"$x,$y"} = 1;
        $m->{minx} = $x if $x < $m->{minx};  $m->{maxx} = $x if $x > $m->{maxx};
        $m->{miny} = $y if $y < $m->{miny};  $m->{maxy} = $y if $y > $m->{maxy};
    }
    close $fh;
}
die "no .lotheader files found -- set PZ=/path/to/ProjectZomboid\n" unless %maps;

# deploy.cmd builds the same map into several trees; count them once.
my %seen;
for my $dir (sort { length($a) <=> length($b) || $a cmp $b } keys %maps) {
    my $k = $maps{$dir}{id} . "\0" . join ' ', sort keys %{ $maps{$dir}{at} };
    if (my $first = $seen{$k}) { $maps{$first}{copies}++; delete $maps{$dir} }
    else { $seen{$k} = $dir; $maps{$dir}{copies} = 1 }
}

# --- group by the lots= chain (union-find over directory names) ---------
my %parent;
sub find { my $k = shift; $parent{$k} //= $k;
           $parent{$k} = find($parent{$k}) if $parent{$k} ne $k; $parent{$k} }
sub union { my ($a, $b) = map { find($_) } @_; $parent{$a} = $b if $a ne $b }

for my $dir (keys %maps) {
    my $id = $maps{$dir}{id};
    find($id);
    if (open my $i, '<', "$dir/map.info") {
        while (<$i>) { s/\s+$//; union($id, $1) if /^lots\s*=\s*(.+)$/ }
        close $i;
    }
}
my %group;
push @{ $group{ find($maps{$_}{id}) } }, $_ for keys %maps;

# --- report -------------------------------------------------------------
my @order = sort { scalar @{ $group{$b} } <=> scalar @{ $group{$a} } || $a cmp $b }
            keys %group;
my ($home_group) = grep { my $g = $_;
    grep { $maps{$_}{label} =~ /phuninteriors/i } @{ $group{$g} } } @order;

for my $g (@order) {
    my @dirs = sort { $maps{$a}{minx} <=> $maps{$b}{minx} } @{ $group{$g} };
    my %owner;
    for my $d (@dirs) { push @{ $owner{$_} }, $maps{$d}{label} for keys %{ $maps{$d}{at} } }

    my ($x0, $x1, $y0, $y1);
    for (keys %owner) {
        my ($x, $y) = split /,/;
        $x0 = $x if !defined $x0 || $x < $x0;   $x1 = $x if !defined $x1 || $x > $x1;
        $y0 = $y if !defined $y0 || $y < $y0;   $y1 = $y if !defined $y1 || $y > $y1;
    }
    my ($w, $h) = ($x1 - $x0 + 1, $y1 - $y0 + 1);

    # Growth is measured against the group's anchor -- the biggest map, i.e.
    # vanilla. Another mod's reach is not a licence to spend bounding box:
    # the player may well not have that mod installed.
    my ($anchor) = sort { $maps{$b}{cells} <=> $maps{$a}{cells} } @dirs;
    my $A = $maps{$anchor};
    my ($ax0, $ax1, $ay0, $ay1) = ($A->{minx}, $A->{maxx}, $A->{miny}, $A->{maxy});
    my $aw = ($ax1 - $ax0 + 1) * ($ay1 - $ay0 + 1);

    printf "\n=== world group %s -- %d map(s) ===\n", $g, scalar @dirs;
    printf "%-40s %6s  %-10s %-8s\n", 'map', 'cells', 'x', 'y';
    for my $d (@dirs) {
        my $m = $maps{$d};
        printf "%-40s %6d  %-10s %-8s %s\n", $m->{label}, $m->{cells},
            "$m->{minx}-$m->{maxx}", "$m->{miny}-$m->{maxy}",
            $m->{copies} > 1 ? "($m->{copies} installed copies)" : '';
    }
    printf "metagrid bbox  cells %d-%d x %d-%d  (%dx%d = %d slots, %dKB of pointers)\n",
        $x0, $x1, $y0, $y1, $w, $h, $w * $h, $w * $h * 8 / 1024;
    printf "isValidSquare  world %d-%d x %d-%d\n",
        $x0 * $CELL, ($x1 + 1) * $CELL - 1, $y0 * $CELL, ($y1 + 1) * $CELL - 1;

    my @clash = grep { @{ $owner{$_} } > 1 } sort keys %owner;
    if (@clash) {
        print "COLLISIONS -- first in load order wins, silently:\n";
        my %pair;
        push @{ $pair{ join ' vs ', sort @{ $owner{$_} } } }, $_ for @clash;
        for my $p (sort keys %pair) {
            printf "  %s\n    %d cell(s): %s\n", $p,
                scalar @{ $pair{$p} }, join ' ', @{ $pair{$p} };
        }
    }

    next unless $g eq ($home_group // '');

    if ($grid) {
        print "\n";
        for my $y ($y0 .. $y1) {
            printf "%3d ", $y;
            for my $x ($x0 .. $x1) {
                my $o = $owner{"$x,$y"};
                print !$o ? '.' : @$o > 1 ? '!'
                    : $o->[0] eq $A->{label} ? '#' : 'o';
            }
            print "\n";
        }
        print "    ", '-' x $w, "\n";
        print "    # anchor   o mod   ! collision   . free\n";
    }

    next unless $findw;

    my @ok;
    for my $y (0 .. $y1 + 8) {
        X: for my $x (0 .. $x1 + 12) {
            for my $dx (0 .. $findw - 1) {
                for my $dy (0 .. $findh - 1) {
                    next X if $owner{ ($x + $dx) . ',' . ($y + $dy) };
                }
            }
            my $near = 1e9;
            for my $k (keys %owner) {
                my ($ox, $oy) = split /,/, $k;
                my $dx = $ox > $x + $findw - 1 ? $ox - ($x + $findw - 1)
                       : $ox < $x             ? $x - $ox : 0;
                my $dy = $oy > $y + $findh - 1 ? $oy - ($y + $findh - 1)
                       : $oy < $y             ? $y - $oy : 0;
                my $m = $dx > $dy ? $dx : $dy;
                $near = $m if $m < $near;
            }
            next if $near < 2;                 # want a gap nobody walks across
            my $nx0 = $ax0 < $x ? $ax0 : $x;
            my $nx1 = $ax1 > $x + $findw - 1 ? $ax1 : $x + $findw - 1;
            my $ny0 = $ay0 < $y ? $ay0 : $y;
            my $ny1 = $ay1 > $y + $findh - 1 ? $ay1 : $y + $findh - 1;
            push @ok, [$x, $y, $near,
                       ($nx1 - $nx0 + 1) * ($ny1 - $ny0 + 1) - $aw];
        }
    }
    @ok = sort { $a->[3] <=> $b->[3] || $b->[2] <=> $a->[2]
              || $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @ok;
    # One row per distinct growth tier, biggest gap in each: the trade-off
    # in a few lines rather than ten adjacent cells that all say the same.
    my (%tier, @pick);
    for my $c (@ok) { push @pick, $c unless $tier{ $c->[3] }++ }

    printf "\nfree %dx%d homes, anchored on %s (cells %d-%d x %d-%d).\n",
        $findw, $findh, $A->{label}, $ax0, $ax1, $ay0, $ay1;
    print "Growth is metagrid pointers only, 8 bytes a slot -- rank on the gap.\n";
    for my $c (@pick[0 .. ($#pick < 11 ? $#pick : 11)]) {
        printf "  %3d,%-3d  world %6d,%-6d  gap %2d cells  bbox %+d slots\n",
            $c->[0], $c->[1], $c->[0] * $CELL, $c->[1] * $CELL, $c->[2], $c->[3];
    }
}
