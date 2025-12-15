use v5.38;
use warnings;
use experimental qw(class signatures);

class PerlSchool::App::LintMS;

use Path::Tiny;
use XML::LibXML;

field $parser = XML::LibXML->new( recover => 0 );
field $errors :reader = 0;
field $files  :param  = [];

# State for current file processing
field $lineno     = 0;
field $in_code    = 0;
field $chunk      = [];
field $chunk_start = 0;
field $current_file = '';

method run_app() {
  die "No files provided\n" unless @$files;
  
  for my $file (@$files) {
    $self->process_file($file);
  }
  
  if ($errors) {
    warn "\nFound $errors invalid HTML/XHTML chunk(s).\n";
    return 1;
  }
  
  say "All HTML chunks look XML-well-formed enough.";
  return 0;
}

method process_file($file) {
  my $path = path($file);
  $current_file = $file;
  $lineno = 0;
  $in_code = 0;
  $chunk = [];
  $chunk_start = 0;
  
  for my $line ($path->lines_utf8) {
    $self->parse_line($line);
  }
  
  # EOF: flush last chunk
  $self->flush_chunk();
}

method parse_line($line) {
  ++$lineno;
  
  # Toggle code-fence state (simple: treat any ``` as fence)
  if ( $line =~ /^```/ ) {
    # Leaving normal text => flush any pending chunk
    if ( !$in_code ) {
      $self->flush_chunk();
    }
    $in_code = !$in_code;
    return;
  }
  
  if ($in_code) {
    # Inside fenced code: ignore completely
    return;
  }
  
  # Blank line => end of chunk
  if ( $line =~ /^\s*$/ ) {
    $self->flush_chunk();
    return;
  }
  
  # Non-blank, non-code line: add to current chunk
  if ( !@$chunk ) {
    $chunk_start = $lineno;
  }
  push @$chunk, $line;
}

method flush_chunk() {
  return unless @$chunk;
  
  my $chunk_text = join('', @$chunk);
  
  # Extract all <tag ...> bits; ignore text between them.
  my @tags = ($chunk_text =~ m{<[^>]+>}g);
  @$chunk = ();
  
  return unless @tags; # no HTML here, nothing to check
  
  $self->validate_html_chunk($chunk_text, @tags);
}

method validate_html_chunk($chunk_text, @tags) {
  my $snippet = "<root>\n" . (join "\n", @tags) . "\n</root>\n";
  
  my $ok = eval {
    $parser->load_xml( string => $snippet );
    1;
  };
  
  if ( !$ok ) {
    ++$errors;
    my $err = $@ // 'Unknown XML error';
    chomp $err;
    
    my $first_line = (split /\n/, $chunk_text)[0] // $chunk_text;
    
    warn <<"EOF";
$current_file:$chunk_start: Invalid XHTML-ish HTML chunk detected:
  $err

  (first line of chunk)
    $first_line
EOF
  }
}

1;

__END__

=head1 NAME

PerlSchool::App::LintMS - Validate HTML/XHTML in Markdown manuscript files

=head1 SYNOPSIS

    use PerlSchool::App::LintMS;
    
    my $app = PerlSchool::App::LintMS->new(
        files => \@ARGV,
    );
    
    exit $app->run_app();

=head1 DESCRIPTION

This class validates HTML/XHTML chunks embedded in Markdown manuscript files.
It extracts HTML tags from non-code sections and validates them for XML well-formedness.

=head1 CONSTRUCTOR PARAMETERS

=head2 files

Array reference of file paths to check. Defaults to an empty array reference.

=head1 FIELDS

=over 4

=item * $parser - XML::LibXML parser instance (initialized with recover => 0)

=item * $errors - Count of validation errors found (readable via ->errors accessor)

=item * $files - Array reference of files to process

=back

Internal state fields used during processing:

=over 4

=item * $lineno - Current line number in file

=item * $in_code - Boolean flag for code fence state

=item * $chunk - Array reference of lines in current chunk

=item * $chunk_start - Line number where current chunk started

=item * $current_file - Name of file being processed

=back

=head1 METHODS

=head2 run_app()

Main entry point that processes all files and reports results.
Returns 0 on success (all chunks valid), 1 if errors were found.

=head2 process_file($file)

Process a single markdown file, parsing lines and validating HTML chunks.

=head2 parse_line($line)

Parse a single line, tracking code fence state and accumulating chunks.

=head2 flush_chunk()

Process the accumulated chunk, extracting HTML tags and validating.

=head2 validate_html_chunk($chunk_text, @tags)

Validate HTML tags using XML parser and report errors.

=cut
