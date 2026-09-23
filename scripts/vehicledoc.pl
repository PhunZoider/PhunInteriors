#!/usr/bin/perl
# Print Docs/vehicles.md from Docs/pi-assigned.csv and Docs/pi-vehicles.csv.
#   perl Docs/vehicledoc.pl > Docs/vehicles.md
# Run from the repo root. The page intro is kept in __DATA__ below.
use strict;
sub rd { my $f=shift; open my $h,'<:encoding(UTF-8)',$f or die; my @r; my $hdr; while(<$h>){ s/^\x{FEFF}//; s/\r?\n$//; next unless length; my @c; while(/\G(?:"([^"]*)"|([^,]*))(,|$)/g){ push @c, defined $1?$1:$2; last if $3 eq ''; } if(!$hdr){$hdr=\@c;next} my %x; @x{@$hdr}=@c; push @r,\%x } @r }
my @rooms = rd('Docs/pi-assigned.csv'); my @veh = rd('Docs/pi-vehicles.csv');
my %byroom; for my $v (@veh){ my $n=$v->{vehicle}; $n=~s/^Base\.//; push @{$byroom{$v->{room}}}, $n }
my %fb; for my $r (@rooms){ next unless $r->{fallback}; for my $t (split /\s*[;|]\s*/, $r->{fallback}) { push @{$fb{$r->{id}}}, $t } }
my %lab = map { $_->{id} => $_->{label} } @rooms;
binmode STDOUT, ":encoding(UTF-8)";
print while <DATA>;
for my $r (sort { $a->{label} cmp $b->{label} } @rooms){
  my @v = sort { lc $a cmp lc $b } do { my %s; grep { !$s{$_}++ } @{$byroom{$r->{id}}||[]} };
  my $fl = "$r->{'floor-w'}x$r->{'floor-h'}";
  my $cab = $r->{cab} eq 'TRUE' ? 'seat' : ($r->{front} ? 'beside' : 'beside');
  printf "| %s | %s | %s | %s |\n", $r->{label}, $fl, (@v ? join(', ', map {"`$_`"} @v) : '*none yet*'), ($r->{fallback} ? ($lab{$r->{fallback}} || $r->{fallback}) : "");
}
__DATA__
# Supported vehicles

Which vehicle opens onto which room. Generated from `Docs/pi-assigned.csv` and
`Docs/pi-vehicles.csv`, the same files `Docs/gendefaults.pl` builds the
registry from; regenerate this page when they change.

Script names drop the `Base.` prefix. Vehicles from other mods are listed by
the script name that mod uses, and only get a room when that mod is installed:
a binding that names a vehicle the game does not have simply never matches.

**Floor** is the floor you can walk on, in squares. **Overflow** is the room a
vehicle is given once every slot of its own room is taken. A room with no
overflow refuses the vehicle when it is full.

A vehicle not listed here has no interior. A server admin can bind one in the
room editor ([admin.md](admin.md)), and a mod can bind its own
([modding.md](modding.md)).

| Room | Floor | Vehicles | Overflow |
|---|---|---|---|
