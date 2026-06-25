use v5.38;
use warnings;
use experimental qw(class signatures);

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
field $kdp           :param = 0;
field $weasyprint    :param = 0;

# Resource paths (initialized with expressions)
field $utils_root       = path($RealBin)->parent->absolute;
field $css_shared       = $utils_root->child('css')->child('book-shared.css');
field $css_pdf          = $utils_root->child('css')->child('book-pdf.css');
field $css_pdf_kdp      = $utils_root->child('css')->child('book-pdf-kdp.css');
field $utils_images_dir = $utils_root->child('images');

# Metadata (loaded from file)
field $meta = do {
  my $m = LoadFile($metadata_file) or die "Failed to load $metadata_file\n";
  # Set default process locale if not already set
  $ENV{LANG} //= 'en_GB.UTF-8';
  $m;
};

# Effective language for this book (BCP-47)
field $effective_lang = $meta->{lang} // 'en-GB';

# Core metadata fields (extracted from $meta)
field $title      = $meta->{title}      // die "Missing required key 'title' in $metadata_file\n";
field $manuscript = $meta->{manuscript} // die "Missing required key 'manuscript' in $metadata_file\n";
field $cover      = $meta->{cover_image} // die "Missing required key 'cover_image' in $metadata_file\n";

# Derived and optional metadata fields
field $output_base       = slugify($title);
field $author           = $meta->{author}           // '';
field $subtitle         = $meta->{subtitle}         // '';
field $publisher        = $meta->{publisher}        // '';
field $isbn             = $meta->{isbn}             // '';
field $copyright_year   = $meta->{copyright_year}   // '';
field $copyright_holder = $meta->{copyright_holder} // $author // $publisher // '';

# Manuscript text (loaded once)
field $manuscript_text = path($manuscript)->slurp_utf8;

# Directory fields (with defaults)
field $build_dir = path('build');
field $built_dir = path('built');

# Template Toolkit instance
field $tt = do {
  Template->new({}) or die Template->error;
};

# Template context (used for rendering templates)
field $template_context = {
  %$meta,
  author           => $author,
  subtitle         => $subtitle,
  publisher        => $publisher,
  isbn             => $isbn,
  copyright_year   => $copyright_year,
  copyright_holder => $copyright_holder,
  cover_image      => $cover,
  lang             => $effective_lang,
};

method run_app() {
  $self->validate_resources();
  $self->display_metadata();
  $self->setup_directories();
  
  my $pdf_front_html = $self->render_pdf_front_matter();
  my $epub_input = $self->render_epub_front_matter();
  
  $self->prepare_images();
  
  my $body_inner = $self->build_body_html();
  my $html_output = $self->stitch_html($pdf_front_html, $body_inner);
  
  my $pdf_file = $self->build_pdf($html_output);
  my $epub_file = $self->build_epub($epub_input);

  my $kdp_pdf_file;
  if ($kdp) {
    my $kdp_front_html  = $self->render_kdp_front_matter();
    my $kdp_html_output = $self->stitch_kdp_html($kdp_front_html, $body_inner);
    $kdp_pdf_file = $self->build_kdp_pdf($kdp_html_output);
  }
  
  $self->cleanup();
  
  say "Built:";
  say "  " . $pdf_file->stringify;
  say "  " . $epub_file->stringify;
  say "  " . $kdp_pdf_file->stringify if $kdp_pdf_file;
  
  return 0;
}

method validate_resources() {
  # Validate required CSS files exist
  my @css_files = ($css_shared, $css_pdf);
  push @css_files, $css_pdf_kdp if $kdp;
  for my $css (@css_files) {
    die "Missing CSS file: $css\n" unless $css->is_file;
  }

  say "UTILS:";
  say "  Root       : $utils_root";
  say "  CSS dir    : " . $utils_root->child('css');
  say "  CSS shared : $css_shared";
  say "  CSS pdf    : $css_pdf";
  say "  CSS pdf kdp: $css_pdf_kdp" if $kdp;
  say "  Images dir : $utils_images_dir";
}

method display_metadata() {
  # Display loaded metadata
  say "METADATA:";
  say "  Manuscript : $manuscript";
  say "  Title      : $title";
  say "  Cover      : $cover";
  say "  Output base: $output_base";
  say "  KDP PDF    : yes" if $kdp;
  say "  Renderer   : " . ($weasyprint ? 'WeasyPrint' : 'wkhtmltopdf');
}

method setup_directories() {
  # Clean and create directories
  if ($build_dir->exists) {
    $build_dir->remove_tree({ safe => 0 });
  }
  $build_dir->mkpath;
  $built_dir->mkpath;
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

  my $pdf_front_html;
  $tt->process(\$pdf_front_tmpl, $template_context, \$pdf_front_html)
    or die "Template error (PDF front matter): " . $tt->error . "\n";

  return $pdf_front_html;
}

method render_kdp_front_matter() {

  # FRONT MATTER FOR KDP PDF — same as render_pdf_front_matter() but without
  # the cover-page section: KDP hard-copy books do not need an image of the
  # cover on the front page (the physical cover is printed separately by KDP).
  my $kdp_front_tmpl = <<'KDP_TMPL';
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
KDP_TMPL

  my $kdp_front_html;
  $tt->process(\$kdp_front_tmpl, $template_context, \$kdp_front_html)
    or die "Template error (KDP front matter): " . $tt->error . "\n";

  return $kdp_front_html;
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

  my $epub_front_md;
  $tt->process(\$epub_front_tmpl, $template_context, \$epub_front_md)
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
    '--metadata', 'toc-title=Table of Contents',
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

  if ($weasyprint) {
    # WeasyPrint: all layout (page size, margins, headers, footers) is driven
    # entirely by book-pdf.css @page rules, so no extra CLI flags are needed.
    run(
      'weasyprint',
      $html_output->stringify,
      $pdf_file->stringify,
    );
  } else {
    run(
      'wkhtmltopdf',
      '--enable-local-file-access',
      '--page-size', 'A4',
      '--margin-top',    '25mm',
      '--margin-bottom', '25mm',
      '--margin-left',   '25mm',
      '--margin-right',  '25mm',
      # Running headers: book title on the left, current chapter (h1) on the right.
      # [doctitle] = HTML <title>; [section] = current h1 heading (wkhtmltopdf outline).
      '--header-left',      '[doctitle]',
      '--header-right',     '[section]',
      '--header-line',
      '--header-font-size', '9',
      # Page number centred in the footer.
      '--footer-center',    '[page]',
      '--footer-font-size', '9',
      $html_output->stringify,
      $pdf_file->stringify,
    );
  }

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

method stitch_kdp_html($pdf_front_html, $body_inner) {
  my $html_output = $build_dir->child('book-kdp.html');

  my $css_shared_uri  = file_uri($css_shared);
  my $css_pdf_kdp_uri = file_uri($css_pdf_kdp);

  my $final_html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>@{[ $title // '' ]}</title>
  <link rel="stylesheet" href="$css_shared_uri" />
  <link rel="stylesheet" href="$css_pdf_kdp_uri" />
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

method build_kdp_pdf($html_output) {
  my $pdf_file = $built_dir->child("$output_base-kdp.pdf");

  if ($weasyprint) {
    # WeasyPrint: all layout (7"×9" page, mirrored margins, headers, footers)
    # is driven entirely by book-pdf-kdp.css @page rules.
    run(
      'weasyprint',
      $html_output->stringify,
      $pdf_file->stringify,
    );
  } else {
    # 7" × 9" (178 mm × 229 mm) — closest KDP standard trim to 18 cm × 23 cm.
    # Left margin is the gutter (inside); right margin is the outside edge.
    run(
      'wkhtmltopdf',
      '--enable-local-file-access',
      '--page-width',    '178mm',
      '--page-height',   '229mm',
      '--margin-top',    '25mm',
      '--margin-bottom', '25mm',
      '--margin-left',   '30mm',
      '--margin-right',  '20mm',
      # Running headers: book title on the left, current chapter (h1) on the right.
      # [doctitle] = HTML <title>; [section] = current h1 heading (wkhtmltopdf outline).
      '--header-left',      '[doctitle]',
      '--header-right',     '[section]',
      '--header-line',
      '--header-font-size', '9',
      # Page number centred in the footer (wkhtmltopdf cannot mirror left/right footers).
      '--footer-center',    '[page]',
      '--footer-font-size', '9',
      $html_output->stringify,
      $pdf_file->stringify,
    );
  }

  return $pdf_file;
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
        kdp           => 0,
        weasyprint    => 0,
    );
    
    $app->run_app();

=head1 DESCRIPTION

This class orchestrates the build process for Perl School books, converting
Markdown manuscripts into professionally formatted PDF and EPUB files.

=head1 CONSTRUCTOR PARAMETERS

=head2 metadata_file

Path to the YAML metadata file. Defaults to 'book-metadata.yml'.

All other fields are initialized automatically from this file during object construction.

=head2 keep_build

Boolean flag to keep the build directory after completion. Defaults to 0 (false).

=head2 weasyprint

Boolean flag to use WeasyPrint as the PDF renderer instead of wkhtmltopdf.
Defaults to 0 (false).

wkhtmltopdf and WeasyPrint have different capability profiles:

=over 4

=item * B<wkhtmltopdf>: handles running headers and footer page numbers via CLI
flags (C<--header-left>, C<--header-right>, C<--footer-center>, etc.).  It does
B<not> support CSS Paged Media Level 3 functions such as C<target-counter()>,
C<leader()>, C<string-set>, or C<break-before: recto>.  TOC page numbers with
dot leaders are therefore B<not> available under wkhtmltopdf.

=item * B<WeasyPrint>: fully implements CSS Paged Media Level 3 including
C<@page :left>/C<:right> margin boxes, C<string-set> running strings,
C<target-counter()>, C<leader()>, and C<break-before: recto>.  All layout
(page size, margins, headers, footers, TOC page numbers) is driven by the CSS
files alone.  WeasyPrint B<does not> support the wkhtmltopdf-style CLI header/
footer flags, but those are not needed when using WeasyPrint.

=back

Pass C<--weasyprint> to C<bin/make_book> to use WeasyPrint.  The C<weasyprint>
binary must be on C<PATH> (it is pre-installed in the Docker image).

=head2 kdp

Boolean flag to additionally generate a KDP/BookBub hard-copy PDF alongside the
standard LeanPub PDF and EPUB. Defaults to 0 (false).

When set, C<make_book> produces an extra file named C<< <slug>-kdp.pdf >> in the
C<built/> directory.  The KDP PDF differs from the LeanPub PDF in the following
ways:

=over 4

=item * B<Page size>: 7" × 9" (178 mm × 229 mm), the closest standard Amazon KDP
trim size to the original 18 cm × 23 cm target.

=item * B<No cover image>: the cover page section is omitted from the KDP front
matter; the physical cover is printed separately by KDP from the cover file
submitted during KDP setup.

=item * B<Font size>: inherits the 12.5 pt base from C<book-shared.css>.
To adjust, add a C<body { font-size: ...; }> rule in C<book-pdf-kdp.css>.

=item * B<Margins>: 30 mm inside (gutter) / 20 mm outside / 25 mm top and bottom,
giving a clear gutter for bound pages and meeting KDP minimum margin requirements.

=item * B<Chapter page starts>: C<break-before: recto> is set on C<h1> elements so
that chapters begin on right-hand (odd-numbered) pages when rendered by a
CSS paged-media renderer such as WeasyPrint.  wkhtmltopdf does not fully
support the C<recto> value and falls back to a plain page break; if strict
recto placement is required, post-process the PDF to insert blank verso
pages where needed.  H2 headings do B<not> force a new page in either PDF.

=item * B<CSS>: uses C<book-pdf-kdp.css> instead of C<book-pdf.css>.

=back

=head1 FIELDS

Most fields are initialized automatically using field initialization expressions:

=over 4

=item * Resource paths ($utils_root, $css_shared, $css_pdf, $css_pdf_kdp, $utils_images_dir) - computed from $RealBin

=item * Metadata ($meta, $title, $manuscript, $cover, etc.) - loaded from metadata_file

=item * Manuscript text ($manuscript_text) - read from manuscript file

=item * Directories ($build_dir, $built_dir) - default paths

=item * Template Toolkit ($tt) - initialized with defaults

=item * Template context ($template_context) - hash of template variables for rendering

=back

=head1 METHODS

=head2 run_app()

Main driver method that orchestrates the entire book build process by calling other methods in sequence.
Returns 0 on success, dies on failure.

=head2 validate_resources()

Validates that required perlschool-utils resources (CSS files) exist.
Also validates the KDP CSS file when the C<kdp> flag is set.
Resource paths are already initialized via field expressions.

=head2 display_metadata()

Displays the loaded metadata information.
Metadata is already loaded and validated via field initialization expressions.

=head2 setup_directories()

Creates and prepares the build and built directories, removing any existing build directory.

=head2 render_pdf_front_matter()

Renders the PDF front matter HTML using Template Toolkit, including cover page, half-title, title page, and copyright page.
Returns the rendered HTML string.

=head2 render_kdp_front_matter()

Like C<render_pdf_front_matter()>, but omits the cover-page section.
KDP hard-copy books do not need a printed cover image in the interior PDF;
the physical cover is supplied separately to KDP.
Returns the rendered HTML string.
Only called when the C<kdp> flag is set.

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
Returns the Path::Tiny object for the stitched HTML file (C<build/book.html>).

=head2 build_pdf($html_output)

Generates the LeanPub PDF file (A4) from the HTML.

When C<weasyprint> is set, calls C<weasyprint> and all layout is driven by
C<book-pdf.css> C<@page> rules (running headers via C<string-set>, page numbers
via C<counter(page)>, TOC page numbers via C<target-counter()>).

When C<weasyprint> is not set, calls C<wkhtmltopdf> with C<--header-left>
(book title), C<--header-right> (current chapter), C<--header-line>, and
C<--footer-center> (page number) CLI flags.  C<target-counter()> and dot leaders
in the TOC are not supported by wkhtmltopdf.

Returns the Path::Tiny object for the generated PDF file.

=head2 stitch_kdp_html($pdf_front_html, $body_inner)

Like C<stitch_html()>, but links C<book-pdf-kdp.css> instead of C<book-pdf.css>
and writes the result to C<build/book-kdp.html>.
Returns the Path::Tiny object for the stitched HTML file.
Only called when the C<kdp> flag is set.

=head2 build_kdp_pdf($html_output)

Generates the KDP hard-copy PDF (7" × 9", mirrored margins) from the HTML.

When C<weasyprint> is set, calls C<weasyprint> and all layout is driven by
C<book-pdf-kdp.css> C<@page> rules (page size, mirrored margins, running headers,
outside-corner page numbers, TOC page numbers via C<target-counter()>).

When C<weasyprint> is not set, calls C<wkhtmltopdf> with explicit page dimensions
and C<--header-left>/C<--header-right>/C<--footer-center> CLI flags.

Returns the Path::Tiny object for the generated KDP PDF file.
Only called when the C<kdp> flag is set.

=head2 build_epub($epub_input)

Generates the EPUB file from the combined Markdown using pandoc.
Returns the Path::Tiny object for the generated EPUB file.

=head2 cleanup()

Removes the build directory unless keep_build is enabled.

=cut
