package PerlSchool::Util;

use v5.32;
use warnings;
use experimental 'signatures';

use Exporter 'import';

our @EXPORT_OK = qw(run slugify file_uri);

# Execute a system command and die on failure
sub run (@cmd) {
  say "+ @cmd";
  system @cmd;
  if ($? == -1) {
    die "Failed to execute @cmd: $!\n";
  } elsif ($? & 127) {
    die sprintf "Command @cmd died with signal %d\n", ($? & 127);
  } elsif ($? != 0) {
    die sprintf "Command @cmd exited with code %d\n", ($? >> 8);
  }
}

# Convert a string to a slug (lowercase, hyphenated)
sub slugify ($s) {
  $s =~ s/^\s+|\s+$//g;
  $s = lc $s;
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  return $s;
}

# Convert a file path to a file:// URI
# Note: Path::Tiny is loaded here on-demand rather than at module load time
# to avoid dependency issues when only using other utility functions
sub file_uri ($path) {
  require Path::Tiny;
  my $abs = Path::Tiny::path($path)->absolute->stringify;
  $abs =~ s/ /%20/g;        # minimal escaping is enough here
  return "file://$abs";
}

1;

__END__

=head1 NAME

PerlSchool::Util - Utility functions for PerlSchool book generation

=head1 SYNOPSIS

    use PerlSchool::Util qw(run slugify file_uri);
    
    run('pandoc', 'input.md', '-o', 'output.pdf');
    my $slug = slugify("My Book Title");
    my $uri = file_uri("/path/to/file.css");

=head1 DESCRIPTION

This module provides utility functions used by the PerlSchool book generation tools.

=head1 FUNCTIONS

=head2 run(@cmd)

Execute a system command and die with a meaningful error if it fails.

=head2 slugify($string)

Convert a string to a slug (lowercase, hyphenated, suitable for filenames).

=head2 file_uri($path)

Convert a file path to a file:// URI with minimal escaping.

=cut
