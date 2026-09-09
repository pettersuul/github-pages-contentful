# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `bundle install` — install Ruby dependencies (run after cloning or after editing the Gemfile)
- `bundle exec jekyll serve` — local dev server at `http://localhost:4000`, loads `.env` via the `dotenv` gem
- `bundle exec jekyll build` — build the static site into `_site/`
- `bundle exec jekyll build --trace` — build with full backtraces (use this when a plugin error is unclear)

There is no test suite or linter configured. Verify changes by running `bundle exec jekyll build --trace` and inspecting the generated HTML in `_site/`.

## Architecture

This is a Jekyll site that pulls its posts from Contentful at **build time** rather than storing post content as files in the repo.

- **`_plugins/contentful_client.rb`** — builds a `Contentful::Client` from `CONTENTFUL_SPACE_ID` / `CONTENTFUL_ACCESS_TOKEN` / `CONTENTFUL_ENVIRONMENT` env vars. Returns `nil` if credentials are missing (local builds without a `.env` still succeed, just with no posts).
- **`_plugins/contentful_posts_generator.rb`** — a `Jekyll::Generator` that runs during the build, fetches entries for the content type named in `_config.yml`'s `contentful_content_type` (default `post`), and turns each entry into a `Jekyll::PageWithoutAFile` at `/posts/<slug>/`. There are no files on disk for individual posts — they only exist as generated pages during a build.
- **Expected Contentful fields** on the `post` content type: `title`, `slug` (used as the URL segment), `body` (rendered as page content — currently treated as plain text/markdown, not Contentful rich text), `publishDate` (used for ordering and displayed via the `post` layout).
- **`index.html`** lists generated post pages by filtering `site.pages` for URLs under `/posts/` (posts aren't a Jekyll collection — they're plain generated pages, so `site.posts` won't include them).

### Why GitHub Actions instead of native GitHub Pages builds

GitHub Pages' built-in Jekyll build runs in "safe mode," which disables custom plugins and network access — incompatible with a generator that calls the Contentful API. Because of this, the site is **not** deployed via GitHub's automatic Jekyll build; instead `.github/workflows/deploy.yml` runs `bundle exec jekyll build` directly (full plugin support) and publishes `_site/` via `actions/deploy-pages`. The GitHub repo's Pages source must be set to "GitHub Actions", not "Deploy from a branch".

Contentful credentials must be present both locally (`.env`, gitignored) and in CI (repo Actions secrets: `CONTENTFUL_SPACE_ID`, `CONTENTFUL_ACCESS_TOKEN`, `CONTENTFUL_ENVIRONMENT`) — the generator silently produces zero posts if they're absent rather than failing the build.
