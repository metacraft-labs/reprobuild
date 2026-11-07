#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

version="$1"
case "${version}" in
  *[!0-9.]*|"") echo "version must contain digits and dots only" >&2; exit 2 ;;
esac

# Validate the complete release-version set before changing any member. The
# core default governs ordinary builds; t_version independently checks both
# that runtime value and the manifest. Preserve the strdefine override.
perl - "$version" <<'PERL'
use strict;
use warnings;
my $version = shift @ARGV;
my @declarations = (
  ['reprobuild.nimble', qr/^version = "([^"]+)"\r?$/m],
  ['nix/pkgs/by-name/re/reprobuild/package.nix', qr/^  version = "([^"]+)";\r?$/m],
  ['libs/repro_core/src/repro_core.nim', qr/^const ReprobuildVersion\* \{\.strdefine\.\} = "([^"]+)"\r?$/m],
  ['tests/unit/t_version.nim', qr/^  ExpectedReprobuildVersion = "([^"]+)"\r?$/m],
);
my (@contents, $previous);
for my $declaration (@declarations) {
  my ($path, $pattern) = @$declaration;
  open my $input, '<', $path or die "bump_version: read $path: $!\n";
  binmode $input or die "bump_version: binmode $path: $!\n";
  local $/;
  my $text = <$input>;
  close $input or die "bump_version: close $path: $!\n";
  my @matches = $text =~ /$pattern/g;
  @matches == 1 or die "bump_version: expected exactly one version declaration in $path\n";
  $previous //= $matches[0];
  $matches[0] eq $previous or die "bump_version: version declarations already disagree at $path\n";
  # Replace only the matched declaration's quoted value, never examples or
  # fixture versions elsewhere in a file.
  $text =~ /$pattern/;
  substr($text, $-[1], $+[1] - $-[1], $version);
  push @contents, $text;
}
for my $index (0 .. $#declarations) {
  my $path = $declarations[$index][0];
  open my $output, '>', $path or die "bump_version: write $path: $!\n";
  binmode $output or die "bump_version: binmode $path: $!\n";
  print {$output} $contents[$index] or die "bump_version: write $path: $!\n";
  close $output or die "bump_version: close $path: $!\n";
}
PERL

bash ./scripts/check_package_nix_version.sh

# The literal's `src` snapshot cannot move in the same commit: it must name a
# PUBLISHED commit whose reprobuild.nimble already says this version.
echo "note: once this bump is pushed, move nix/pkgs/by-name/re/reprobuild/package.nix's \`src\` (rev, hash)" \
  "and *Src defaults to it; nixpkgs-package-src-sync checks that snapshot" >&2
