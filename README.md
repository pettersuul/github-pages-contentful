# github-pages-contentful

A Jekyll site whose posts are fetched from Contentful at build time and deployed to GitHub Pages via GitHub Actions.

Native GitHub Pages builds run Jekyll in "safe mode," which disables custom plugins and network access — so this site can't rely on GitHub's built-in Jekyll build. Instead, a GitHub Actions workflow ([.github/workflows/deploy.yml](.github/workflows/deploy.yml)) runs `jekyll build` with full plugin support and deploys the resulting `_site/` to Pages.

## Setup

1. Install dependencies: `bundle install`
2. Copy `.env.example` to `.env` and fill in your Contentful credentials:
   ```
   CONTENTFUL_SPACE_ID=
   CONTENTFUL_ACCESS_TOKEN=
   CONTENTFUL_ENVIRONMENT=master
   ```
3. In the GitHub repo settings, add the same three values as Actions secrets (`CONTENTFUL_SPACE_ID`, `CONTENTFUL_ACCESS_TOKEN`, `CONTENTFUL_ENVIRONMENT`), and set Pages source to "GitHub Actions".

## Content model

The build expects a Contentful content type (id configurable via `contentful_content_type` in [_config.yml](_config.yml), defaults to `post`) with these fields:

- `title` (text)
- `slug` (text) — used as the URL path: `/posts/<slug>/`
- `body` (text/markdown) — rendered as the page content
- `publishDate` (date) — used for ordering and displayed on the post page

## Commands

- `bundle exec jekyll serve` — run the local dev server at `http://localhost:4000` (reads `.env` via the `dotenv` gem)
- `bundle exec jekyll build` — build the static site into `_site/`
- `bundle exec jekyll build --trace` — build with full backtraces on plugin errors
