#!/usr/bin/perl
# Locals redeclared at the top level of the same function body.
#
#   perl Tests/shadow.pl <file.lua>...
#
# LuaJIT parses a shadowed local perfectly happily, and the failure it causes
# is silent and remote: Transit.leave declared a second `destination` eighty
# lines after the first, which replaced the position resolveReturn had worked
# out with a landing-area string, so every exit sent a teleport to nil,nil and
# the CLIENT died on `nil + 0.5`. Nothing in the stack trace pointed at the
# declaration.
#
# Deliberately crude: it only looks at declarations one indent deep inside a
# function, so shadowing inside a nested do/for/if block -- which is often
# meant -- is invisible to it. At the top level of a function it is never meant.

use strict; use warnings;
my @files = @ARGV;
for my $f (@files) {
    open(my $fh, "<", $f) or next;
    my (@lines) = <$fh>; close $fh;
    my ($in, $start, $depth, %seen, $fname);
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        $l =~ s/\s+$//;
        next if $l =~ /^\s*--/;
        if (!$in && $l =~ /^(local\s+)?function\s+([\w.:]+)/) {
            $in = 1; $fname = $2; $start = $i + 1; %seen = (); $depth = 0;
        }
        next unless $in;
        # only count top-level-of-function declarations: one indent unit
        if ($l =~ /^    local\s+([\w, ]+?)\s*=/) {
            for my $n (split /\s*,\s*/, $1) {
                next unless $n =~ /^\w+$/;
                printf("%s:%d  %s redeclares '%s' (first at line %d)\n",
                    $f, $i + 1, $fname, $n, $seen{$n}) if $seen{$n};
                $seen{$n} //= $i + 1;
            }
        }
        if ($l =~ /^end\b/) { $in = 0 }
    }
}
