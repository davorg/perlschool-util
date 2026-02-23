# Perl School utilities

This repo contains

* a number of useful utility programs for producing Perl School books
* a Dockerfile that produces a Docker image with all of these utilities installed
* a GitHub Actions workflow that uses these utilities to regenerate the book

There are more details on these components below.

## About Perl School

The Perl School brand has its roots in a series of low-cost Perl training
courses that [Dave Cross](https://davecross.co.uk/) ran in 2012. By running
low-cost training at the weekend, he hoped to encourage more programmers to
keep their Perl knowledge up to date. These courses were run regularly for
about a year before the idea was put on hold for a while.

Dave always knew that he would want to return to the Perl School brand at some
point and late in 2017 he realised what the obvious next step was - low-cost
Perl books. He had already developed a pipeline for creating e-books from
Markdown files so it was a short step to republishing some of his training
materials as books.

The first Perl School book,
[*Perl Taster*](https://perlschool.com/books/perl-taster/) was published at
the end of 2017 (just in time for the London Perl Workshop). The second was
[*Selenium and Perl*](https://perlschool.com/books/selenium-perl/) and
[several more](https://perlschool.com/books/) have followed since then. This
book introduces a new author to the Perl School stable.

You can read more about Perl School at
[perlschool.com](https://perlschool.com/).

## Utility programs

This repo currently provides two primary utilities, both written in modern
Perl and intended to be run either locally (with the right toolchain
installed) or via the Docker image described below.

### `bin/check_ms_html`

[`check_ms_html`](bin/check_ms_html) is a pre-flight linter for manuscripts
written in Markdown/Markua with embedded HTML. Its job is to catch HTML that
will break when converted to EPUB (which uses XHTML under the hood).

In broad terms it:

* Reads one or more manuscript files (typically the main book manuscript).
* Ignores fenced code blocks (` ``` `) so example code containing `<` / `>`
  is not treated as HTML.
* For the remaining text, extracts any raw HTML fragments and wraps them in a
  temporary XML root element.
* Uses `XML::LibXML` to check that these fragments are **well-formed XML**
  (e.g. `<br />` instead of `<br>`, balanced tags, valid attribute syntax).
* Reports any problems with file name and line number, and exits non-zero if
  it finds invalid fragments.

The intent is that you run `check_ms_html` before `make_book` in order to
catch issues like unclosed `<br>` tags before they reach `pandoc` /
`epubcheck`.

### `bin/make_book`

[`make_book`](bin/make_book) is the main build orchestrator for a Perl School
book. Given a book repo containing a `book-metadata.yml` file, it will:

* Read `book-metadata.yml` (using `YAML::XS`) and extract at least:

  * `title`
  * `manuscript` (path to the main Markdown file)
  * `cover_image` (path to the cover image, usually under `images/`)
* Generate HTML front matter using Template Toolkit:

  * Cover page (full-page cover image)
  * Half-title page
  * Title page (title, subtitle, author)
  * Copyright page (using standard Perl School wording and metadata such as
    year, holder, publisher and ISBN).
* Convert the manuscript to HTML using `pandoc`, asking it to generate a
  Table of Contents but **not** to add its own title page/front matter.
* Stitch the front matter HTML and the `pandoc`-generated body HTML together
  into a single `book.html`, with the appropriate CSS (`book-shared.css` and
  `book-pdf.css`) wired in.
* Call `wkhtmltopdf` on `book.html` to generate a print-ready A4 PDF,
  writing it to the `built/` directory.
* Build an EPUB version via `pandoc`, combining a Markdown copyright page
  with the manuscript, and using `book-metadata.yml` for metadata and the
  cover image.

#### KDP / hard-copy PDF (`--kdp`)

Pass `--kdp` to additionally produce a PDF suitable for upload to Amazon KDP
or BookBub's hard-copy creator.  The KDP PDF differs from the standard
LeanPub PDF in the following ways:

| Property | LeanPub PDF | KDP PDF |
|---|---|---|
| Page size | A4 (210 mm × 297 mm) | 7" × 9" (178 mm × 229 mm) |
| Top / bottom margins | 25 mm | 25 mm |
| Inside (gutter) margin | 25 mm | 30 mm |
| Outside margin | 25 mm | 20 mm |
| Chapter page starts | New page | Recto (odd-numbered) page† |
| CSS file | `book-pdf.css` | `book-pdf-kdp.css` |
| Output filename | `<slug>.pdf` | `<slug>-kdp.pdf` |

† `break-before: recto` is applied via CSS.  WeasyPrint honours it fully.
wkhtmltopdf does not fully support the `recto` value and falls back to a
plain page break.  If strict right-hand chapter starts are required when
using wkhtmltopdf, post-process the generated PDF to insert blank verso pages
where needed.

The 7" × 9" trim size is the closest standard KDP format to the original
18 cm × 23 cm target.

`make_book` creates a temporary `build/` directory for intermediate files and
writes final artefacts (`.pdf`, `-kdp.pdf` when `--kdp` is set, and `.epub`)
under `built/`. By default it removes `build/` at the end of a successful
run; you can pass `--keep-build` when debugging.

Both utilities assume that external tools (`pandoc`, `wkhtmltopdf`, Java,
`epubcheck`) are available on `PATH`. When run inside the Docker image, these
are all preinstalled.

## Docker image

The repository includes a `Dockerfile` and helper script for building a
Docker image that contains all required tools (Perl, CPAN modules, pandoc,
wkhtmltopdf, Java, epubcheck) and this repo itself. The image is intended to
be used from individual book repos, mounting a book directory at `/work` and
running `make_book`, `check_ms_html` and `epubcheck` inside the container.

Full details on building, tagging and using the image are in
[`DOCKER.md`](DOCKER.md).

## GitHub Actions workflow

The expected deployment model is that **each book repo** (e.g. the repo for a
particular Perl School title) includes a GitHub Actions workflow that uses the
`davorg/perlschool-util` image to lint the manuscript, build the book and run
`epubcheck` on the generated EPUB.

A typical workflow:

1. Runs on a standard GitHub-hosted runner (`ubuntu-latest`).
2. Uses the `container:` option to run all steps inside a specific
   `davorg/perlschool-util` image tag (e.g. `1.0.0`).
3. Checks out the book repo.
4. Runs a **pre-flight** Perl script that:

   * Verifies that `book-metadata.yml` exists.
   * Parses it with `YAML::XS`.
   * Checks that `title`, `manuscript` and `cover_image` are present and
     non-empty.
   * Verifies that the manuscript file and cover image actually exist.
5. Runs `check_ms_html` against the manuscript to catch invalid HTML/XHTML
   before conversion.
6. Runs `make_book` to generate the PDF and EPUB into the repo’s `built/`
   directory.
7. Runs `epubcheck` against the generated EPUB(s) to ensure the file
   validates cleanly.
8. Uploads the contents of `built/` as workflow artefacts so they can be
   downloaded from the Actions UI.

A minimal example workflow file for a book repo lives in
[`github-actions-example.yml`](github-actions-example.yml).

Individual book repos are free to adapt this example (for example, to use
specific image tags, only run on certain branches, or to trigger on tags
instead of every push), but the general pattern should remain the same.

