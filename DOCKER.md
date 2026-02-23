# Docker Image for perlschool-util

This repository includes a Docker image that bundles all the tools and dependencies needed to build Perl School books (PDF + EPUB) in a consistent environment.

The image contains:

* Ubuntu base
* Perl, `cpanm`, and all CPAN dependencies from this repo’s `cpanfile`
* `pandoc`
* `wkhtmltopdf`
* `weasyprint`
* Java runtime
* `epubcheck`
* This repo itself, installed at `/opt/perlschool-util`
* Convenience wrappers:

  * `make_book`
  * `check_ms_html`
  * `epubcheck` / `epub_check`

All you need to provide is a **book repo** containing:

* `book-metadata.yml`
* The manuscript (referenced from `book-metadata.yml`)
* Any book-specific `images/` used in the manuscript

---

## Image name

By default, we build and publish the image as:

```text
davorg/perlschool-util
```

You can override this with the `IMAGE_NAME` environment variable if needed.

---

## Building the image

Use the `build_docker` script at the root of this repo.

You **must** supply a SemVer version number (`X.Y.Z`). The script will:

* Build the image as `IMAGE_NAME:X.Y.Z`
* Also tag it as `IMAGE_NAME:latest`
* Push both tags to Docker Hub

Example:

```bash
# From the perlschool-util repo root
./build_docker 1.0.0
```

This will build and push:

* `davorg/perlschool-util:1.0.0`
* `davorg/perlschool-util:latest`

To use a different repo:

```bash
IMAGE_NAME=myorg/perlschool-util ./build_docker 1.2.3
```

> **Note:** `build_docker` requires Docker to be installed and logged in to the appropriate Docker Hub account.

---

## Running the tools with Docker

The image is designed to be run **from inside a book repo**.

A typical book repo contains:

* `book-metadata.yml`
* `manuscript.md` (or similar, referenced from `book-metadata.yml` as `manuscript:`)
* `images/` directory

You mount the book repo into `/work` and run the tools from there.

### Example: build PDF + EPUB

From inside the book repo:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work \
  davorg/perlschool-util:latest \
  make_book
```

This will:

* Run `make_book` inside the container
* Read metadata from `book-metadata.yml`
* Generate:

  * `built/<slugified-title>.pdf`
  * `built/<slugified-title>.epub`

### Example: check manuscript HTML

To run the manuscript HTML/XHTML linter:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work \
  davorg/perlschool-util:latest \
  check_ms_html path/to/manuscript.md
```

If your manuscript is referenced in `book-metadata.yml` as `manuscript:`, you can also use that value directly.

### Example: run epubcheck on the generated EPUB

Assuming you’ve already run `make_book` and it produced `built/design-patterns-in-modern-perl.epub`:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work \
  davorg/perlschool-util:latest \
  epubcheck built/design-patterns-in-modern-perl.epub
```

`epubcheck` is a small wrapper that runs:

```bash
java -jar /opt/epubcheck/epubcheck.jar <args>
```

You can also use the alias `epub_check` if you prefer.

### Example: build PDF with WeasyPrint (TOC page numbers + dot leaders)

The default PDF renderer is **wkhtmltopdf**.  It does not support the CSS
Paged Media Level 3 features needed for TOC page numbers with dot leaders
(`target-counter()`, `leader()`), running headers via `string-set`, or strict
recto chapter starts (`break-before: recto`).

**WeasyPrint** implements all of these.  To use it, pass `--weasyprint`:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work \
  davorg/perlschool-util:latest \
  make_book --weasyprint
```

With `--weasyprint`:

* Page size, margins, running headers, and page numbers are all driven by
  `book-pdf.css` (or `book-pdf-kdp.css` for `--kdp`) `@page` rules.
* The TOC shows dot-leader entries with correct page numbers.
* Chapter headings start on recto (right-hand, odd-numbered) pages when
  `--kdp` is also set.

To generate a KDP hard-copy PDF with WeasyPrint:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work \
  davorg/perlschool-util:latest \
  make_book --kdp --weasyprint
```

---

## How it’s wired inside the container

For reference, the Docker image is structured like this:

* `/opt/perlschool-util` – this repo

  * `bin/make_book`
  * `bin/check_ms_html`
  * `css/book-shared.css`
  * `css/book-pdf.css`
  * `images/perlschool-logo.png`
* `/opt/epubcheck/epubcheck.jar` – the epubcheck JAR
* `/usr/local/bin/make_book` – symlink to `/opt/perlschool-util/bin/make_book`
* `/usr/local/bin/check_ms_html` – symlink to `/opt/perlschool-util/bin/check_ms_html`
* `/usr/local/bin/epubcheck` – small shell wrapper around the epubcheck JAR
* `/usr/local/bin/epub_check` – alias to `epubcheck`
* Default working directory: `/work`

So when you run:

```bash
docker run --rm -v "$PWD":/work -w /work davorg/perlschool-util:latest make_book
```

inside the container:

* `make_book` runs from `/usr/local/bin/make_book`
* It finds its CSS and images via `FindBin` under `/opt/perlschool-util`
* It reads and writes files under `/work` (your mounted book repo)

---

## Using the image in CI (outline)

In GitHub Actions (or any CI system with Docker available), a typical job would:

1. Check out the **book repo**
2. Run the container to:

   * lint the manuscript
   * build the book
   * run epubcheck
3. Upload `built/*.pdf` and `built/*.epub` as build artefacts

Example job outline (GitHub Actions):

```yaml
jobs:
  build-book:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build book (PDF + EPUB)
        run: |
          docker run --rm \
            -v "$PWD":/work \
            -w /work \
            davorg/perlschool-util:latest \
            make_book

      - name: Run epubcheck
        run: |
          docker run --rm \
            -v "$PWD":/work \
            -w /work \
            davorg/perlschool-util:latest \
            epubcheck built/design-patterns-in-modern-perl.epub

      - name: Upload artefacts
        uses: actions/upload-artifact@v4
        with:
          name: book-files
          path: built/*
```

(You can refine this per book, but the pattern is the same.)

---

If you change dependencies in `cpanfile` or update the tools in this repo, remember to rebuild and push a new image version with `./build_docker X.Y.Z`. New CI runs can then pin to that version or keep using `:latest`, depending on how conservative you want to be.
