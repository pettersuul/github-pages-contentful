# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bundle install` — install Ruby dependencies (run after cloning or after editing the Gemfile)
- `bundle exec jekyll serve` — local dev server at `http://localhost:4000`, loads `.env` via the `dotenv` gem
- `bundle exec jekyll build` — build the static site into `_site/`
- `bundle exec jekyll build --trace` — build with full backtraces (use this when a plugin error is unclear)

There is no test suite or linter configured. Verify changes by running `bundle exec jekyll build --trace` and inspecting the generated HTML in `_site/`.

## Architecture

This repo is a **GitHub template repo** for basic Contentful-backed Jekyll sites — it's meant to be reused via "Use this template" rather than modified in place for one specific site. The reuse mechanism is config-driven: adapting the template to a new site's content types means editing `_config.yml`, not the generator plugin.

The site pulls its content from Contentful at **build time** rather than storing pages as files in the repo:

- **`_plugins/contentful_client.rb`** — builds a `Contentful::Client` from `CONTENTFUL_SPACE_ID` / `CONTENTFUL_ACCESS_TOKEN` / `CONTENTFUL_ENVIRONMENT` env vars. Returns `nil` if credentials are missing (local builds without a `.env` still succeed, just with no generated pages).
- **`_plugins/contentful_entries_generator.rb`** — a `Jekyll::Generator` that runs during the build, iterates the `contentful_collections` list in `_config.yml` (each entry: `content_type`, `layout`, `dir`), fetches entries for each content type, and turns each entry into a `Jekyll::PageWithoutAFile` at `/<dir>/<slug>/` (`dir: ""` → site root). There are no files on disk for individual entries — they only exist as generated pages during a build. To add a new content type, add a `contentful_collections` entry and a matching layout; no Ruby changes needed.
- **Expected Contentful fields**: every content type needs `title`, `slug` (used as the URL segment), and `body` (rendered as page content — currently treated as plain text/markdown, not Contentful rich text). The default `post` collection additionally uses `publishDate` for ordering and display.
- **`index.html`** lists generated post pages by filtering `site.pages` for URLs under `/posts/` (posts aren't a Jekyll collection — they're plain generated pages, so `site.posts` won't include them).
- **`_layouts/default.html`** builds a nav from every generated page with `layout: page`, sorted by title — so any `page`-collection entry (About, Contact, etc.) automatically appears in site navigation.

### Why GitHub Actions instead of native GitHub Pages builds

GitHub Pages' built-in Jekyll build runs in "safe mode," which disables custom plugins and network access — incompatible with a generator that calls the Contentful API. Because of this, the site is **not** deployed via GitHub's automatic Jekyll build; instead `.github/workflows/deploy.yml` runs `bundle exec jekyll build` directly (full plugin support) and publishes `_site/` via `actions/deploy-pages`. The GitHub repo's Pages source must be set to "GitHub Actions", not "Deploy from a branch".

Contentful credentials must be present both locally (`.env`, gitignored) and in CI (repo Actions secrets: `CONTENTFUL_SPACE_ID`, `CONTENTFUL_ACCESS_TOKEN`, `CONTENTFUL_ENVIRONMENT`) — the generator silently produces zero posts if they're absent rather than failing the build.
