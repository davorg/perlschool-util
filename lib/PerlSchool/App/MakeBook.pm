use v5.38;
use warnings;
use experimental 'class';
use experimental 'signatures';

class PerlSchool::App::MakeBook;

use Path::Tiny;
use YAML::XS qw(LoadFile);
use Template;
use FindBin qw($RealBin);
use File::Copy::Recursive qw(dircopy);
use File::Copy qw(copy);
use PerlSchool::Util qw(run slugify file_uri);

field $metadata_file :param = 'book-metadata.yml';
field $keep_build    :param = 0;

# Resource paths (with computed defaults)
field $utils_root       = path($RealBin)->parent->absolute;
field $css_shared       = $utils_root->child('css')->child('book-shared.css');
field $css_pdf          = $utils_root->child('css')->child('book-pdf.css');
field $utils_images_dir = $utils_root->child('images');

# Metadata fields
field $meta;
field $effective_lang;
field $title;
field $manuscript;
field $manuscript_text;
field $cover;
field $output_base;
field $author;
field $subtitle;
field $publisher;
field $isbn;
field $copyright_year;
field $copyright_holder;

# Directory fields (with defaults)
field $build_dir = path('build');
field $built_dir = path('built');

# Template Toolkit instance (with default)
field $tt = Template->new({}) or die Template->error;

method run() {
  $self->validate_resources();
  $self->load_metadata();
  $self->setup_directories();
  
  my $pdf_front_html = $self->render_pdf_front_matter();
  my $epub_input = $self->render_epub_front_matter();
  
  $self->prepare_images();
  
  my $body_inner = $self->build_body_html();
  my $html_output = $self->stitch_html($pdf_front_html, $body_inner);
  
  my $pdf_file = $self->build_pdf($html_output);
  my $epub_file = $self->build_epub($epub_input);
  
  $self->cleanup();
  
  say "Built:";
  say "  " . $pdf_file->stringify;
  say "  " . $epub_file->stringify;
  
  return 0;
}

method validate_resources() {
  for my $css ($css_shared, $css_pdf) {
    die "Missing CSS file: $css\n" unless $css->is_file;
  }

  say "UTILS:";
  say "  Root       : $utils_root";
  say "  CSS dir    : " . $utils_root->child('css');
  say "  CSS shared : $css_shared";
  say "  CSS pdf    : $css_pdf";
  say "  Images dir : $utils_images_dir";
}

method load_metadata() {
  $meta = LoadFile($metadata_file)
    or die "Failed to load $metadata_file\n";

  for my $required (qw/title manuscript cover_image/) {
    die "Missing required key '$required' in $metadata_file\n"
      unless defined $meta->{$required} && length $meta->{$required};
  }

  # Effective language for this book (BCP-47)
  $effective_lang = $meta->{lang} // 'en-GB';

  # Default process locale if not already set
  $ENV{LANG} //= 'en_GB.UTF-8';

  $title      = $meta->{title};
  $manuscript = $meta->{manuscript};
  $cover      = $meta->{cover_image};

  $output_base = slugify($title);

  $author           = $meta->{author}           // '';
  $subtitle         = $meta->{subtitle}         // '';
  $publisher        = $meta->{publisher}        // '';
  $isbn             = $meta->{isbn}             // '';
  $copyright_year   = $meta->{copyright_year}   // '';
  $copyright_holder = $meta->{copyright_holder} // $author // $publisher // '';

  say "METADATA:";
  say "  Manuscript : $manuscript";
  say "  Title      : $title";
  say "  Cover      : $cover";
  say "  Output base: $output_base";
  
  # Read manuscript text once
  $manuscript_text = path($manuscript)->slurp_utf8;
}

method setup_directories() {
  if ($build_dir->exists) {
    $build_dir->remove_tree({ safe => 0 });
  }
  $build_dir->mkpath;
  $built_dir->mkpath;
}

method build_template_context() {
  return (
    %$meta,
    author           => $author,
    subtitle         => $subtitle,
    publisher        => $publisher,
    isbn             => $isbn,
    copyright_year   => $copyright_year,
    copyright_holder => $copyright_holder,
    cover_image      => $cover,
    lang             => $effective_lang,
  );
}

method render_pdf_front_matter() {

  # FRONT MATTER FOR PDF (HTML fragment, not Markdown)
  my $pdf_front_tmpl = <<'PDF_TMPL';
<section class="cover-page">
  <img class="cover-image" src="[% cover_image %]" alt="">
</section>

<section class="half-title">
  <h1>[% title %]</h1>
</section>

<section class="title-page">
  <h1>[% title %]</h1>
[% IF subtitle %]
  <h2 class="subtitle">[% subtitle %]</h2>
[% END %]
[% IF author %]
  <p class="author">[% author %]</p>
[% END %]
</section>

<section class="copyright-page">
  <p class="title">[% title %]</p>
  <p>&copy; [% copyright_year %] [% copyright_holder %] . All rights reserved.</p>

[% IF isbn -%]
  <p>ISBN: [% isbn %]</p>
[% END -%]

[% IF publisher -%]
  <p>Published by [% publisher %].</p>
[% END -%]

[% IF publisher_web -%]
  <p>[% publisher_web %]</p>
[% END -%]

  <p>No part of this publication may be reproduced, stored in a retrieval system, or
    transmitted in any form or by any means, electronic, mechanical, photocopying,
    recording or otherwise, without the prior written permission of the publisher,
    except in the case of brief quotations embodied in critical articles and reviews.</p>

  <p>The information in this book is distributed on an "as is" basis, without warranty.
    While every precaution has been taken in the preparation of this book, neither the
    author nor the publisher shall have any liability to any person or entity with
    respect to any loss or damage caused or alleged to be caused directly or indirectly
    by the instructions, examples, or other content contained in this book.</p>

  <p>Set in Markdown and typeset to PDF/ePub with Pandoc and wkhtmltopdf.</p>
</section>
PDF_TMPL

  my %ctx = $self->build_template_context();

  my $pdf_front_html;
  $tt->process(\$pdf_front_tmpl, \%ctx, \$pdf_front_html)
    or die "Template error (PDF front matter): " . $tt->error . "\n";

  return $pdf_front_html;
}

method render_epub_front_matter() {
  my $tt = Template->new({}) or die Template->error;

  # EPUB still uses a simple Markdown copyright page
  my $epub_front_tmpl = <<'EPUB_TMPL';
[%# EPUB front matter: copyright page only %]

*[% title %]*

&copy; [% copyright_year %] [% copyright_holder %]. All rights reserved.

[% IF isbn %]
ISBN: [% isbn %]
[% END %]

[% IF publisher %]
Published by [% publisher %].
[% END %]

[% IF publisher AND publisher_web -%]
[[% publisher %]](https://[% publisher_web %]/)
[% END -%]

No part of this publication may be reproduced, stored in a retrieval system, or
transmitted in any form or by any means, electronic, mechanical, photocopying,
recording or otherwise, without the prior written permission of the publisher,
except in the case of brief quotations embodied in critical articles and reviews.

The information in this book is distributed on an "as is" basis, without warranty.
While every precaution has been taken in the preparation of this book, neither the
author nor the publisher shall have any liability to any person or entity with
respect to any loss or damage caused or alleged to be caused directly or indirectly
by the instructions, examples, or other content contained in this book.

Set in Markdown and typeset to PDF/ePub with Pandoc and wkhtmltopdf.

EPUB_TMPL

  my %ctx = $self->build_template_context();

  my $epub_front_md;
  $tt->process(\$epub_front_tmpl, \%ctx, \$epub_front_md)
    or die "Template error (EPUB front matter): " . $tt->error . "\n";

  # For EPUB we still build a Markdown file: copyright page + manuscript
  my $epub_input = $build_dir->child('epub_input.md');
  $epub_input->spew_utf8($epub_front_md, "\n\n", $manuscript_text);

  return $epub_input;
}

method prepare_images() {
  my $book_images_dir  = path('images');
  my $build_images_dir = $build_dir->child('images');

  if ( $book_images_dir->is_dir ) {
    dircopy($book_images_dir->stringify, $build_images_dir->stringify)
      or die "Failed to copy images/ into build/images/\n";
  }

  my $logo_name  = 'perlschool-logo.png';
  my $build_logo = $build_images_dir->child($logo_name);

  if ( !$build_logo->is_file ) {
    my $utils_logo = $utils_images_dir->child($logo_name);
    if ( $utils_logo->is_file ) {
      $build_images_dir->mkpath;
      copy($utils_logo->stringify, $build_logo->stringify)
        or die "Failed to copy $utils_logo to $build_logo: $!\n";
    }
  }
}

method build_body_html() {
  my $body_html_path = $build_dir->child('body.html');

  run(
    'pandoc',
    $manuscript,
    '--from=markdown',
    '--toc',
    '--toc-depth=2',
    '--standalone',
    '--resource-path=.:images',
    '-o', $body_html_path->stringify,
    ( $meta->{lang} ? () : ('--metadata', "lang=$effective_lang") ),
  );

  my $body_full = $body_html_path->slurp_utf8;

  # Extract just the contents of <body>...</body>
  $body_full =~ s{.*?<body[^>]*>}{}s;
  $body_full =~ s{</body>.*}{}s;
  
  return $body_full;
}

method stitch_html($pdf_front_html, $body_inner) {
  my $html_output = $build_dir->child('book.html');

  my $css_shared_uri = file_uri($css_shared);
  my $css_pdf_uri    = file_uri($css_pdf);

  my $final_html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>@{[ $title // '' ]}</title>
  <link rel="stylesheet" href="$css_shared_uri" />
  <link rel="stylesheet" href="$css_pdf_uri" />
</head>
<body>
$pdf_front_html

$body_inner
</body>
</html>
HTML

  $html_output->spew_utf8($final_html);
  
  return $html_output;
}

method build_pdf($html_output) {
  my $pdf_file = $built_dir->child("$output_base.pdf");

  run(
    'wkhtmltopdf',
    '--enable-local-file-access',
    '--page-size', 'A4',
    '--margin-top',    '25mm',
    '--margin-bottom', '25mm',
    '--margin-left',   '25mm',
    '--margin-right',  '25mm',
    $html_output->stringify,
    $pdf_file->stringify,
  );
  
  return $pdf_file;
}

method build_epub($epub_input) {
  my $epub_file = $built_dir->child("$output_base.epub");

  my @epub_resource_paths = (
    '.',
    'images',
    $utils_images_dir->stringify,
  );

  run(
    'pandoc',
    $epub_input->stringify,
    '--from=markdown',
    "--metadata-file=$metadata_file",
    '--standalone',
    '--resource-path=' . join(':', @epub_resource_paths),
    '-c', $css_shared->stringify,
    "--epub-cover-image=$cover",
    ( $meta->{lang} ? () : ('--metadata', "lang=$effective_lang") ),
    '-o', $epub_file->stringify,
  );
  
  return $epub_file;
}

method cleanup() {
  unless ($keep_build) {
    say "Removing build directory...";
    $build_dir->remove_tree({ safe => 0 });
  }
}

1;

__END__

=head1 NAME

PerlSchool::App::MakeBook - Build PDF and EPUB books from Markdown manuscripts

=head1 SYNOPSIS

    use PerlSchool::App::MakeBook;
    
    my $app = PerlSchool::App::MakeBook->new(
        metadata_file => 'book-metadata.yml',
        keep_build    => 0,
    );
    
    $app->run();

=head1 DESCRIPTION

This class orchestrates the build process for Perl School books, converting
Markdown manuscripts into professionally formatted PDF and EPUB files.

=head1 CONSTRUCTOR PARAMETERS

=head2 metadata_file

Path to the YAML metadata file. Defaults to 'book-metadata.yml'.

=head2 keep_build

Boolean flag to keep the build directory after completion. Defaults to 0 (false).

=head1 METHODS

=head2 run()

Main driver method that orchestrates the entire book build process by calling other methods in sequence.
Returns 0 on success, dies on failure.

=head2 validate_resources()

Validates that required perlschool-utils resources (CSS files) exist and displays resource paths.

=head2 load_metadata()

Loads and validates the book metadata from the YAML file, extracting title, manuscript, cover image, and other metadata.
Also reads the manuscript text into memory.

=head2 setup_directories()

Creates and prepares the build and built directories, removing any existing build directory.

=head2 build_template_context()

Helper method that constructs the template context hash with all metadata fields.
Returns a hash of template variables.

=head2 render_pdf_front_matter()

Renders the PDF front matter HTML using Template Toolkit, including cover page, half-title, title page, and copyright page.
Returns the rendered HTML string.

=head2 render_epub_front_matter()

Renders the EPUB front matter as Markdown, combines it with the manuscript, and writes to an input file for pandoc.
Returns the Path::Tiny object for the combined EPUB input file.

=head2 prepare_images()

Copies book images and perlschool logo to the build directory for inclusion in the final output.

=head2 build_body_html()

Converts the manuscript to HTML using pandoc, extracting the body content.
Returns the body HTML as a string.

=head2 stitch_html($pdf_front_html, $body_inner)

Combines the PDF front matter HTML and body HTML into a complete HTML document with CSS references.
Returns the Path::Tiny object for the stitched HTML file.

=head2 build_pdf($html_output)

Generates the PDF file from the HTML using wkhtmltopdf.
Returns the Path::Tiny object for the generated PDF file.

=head2 build_epub($epub_input)

Generates the EPUB file from the combined Markdown using pandoc.
Returns the Path::Tiny object for the generated EPUB file.

=head2 cleanup()

Removes the build directory unless keep_build is enabled.

=cut
