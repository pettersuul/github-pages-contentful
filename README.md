# github-pages-contentful

A Jekyll template for basic Contentful-backed sites: content is fetched from Contentful at build time and deployed to GitHub Pages via GitHub Actions.

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

To build against draft (unpublished) content instead of only published entries, set `CONTENTFUL_PREVIEW=true` and `CONTENTFUL_PREVIEW_ACCESS_TOKEN` (a separate token from your CDA `CONTENTFUL_ACCESS_TOKEN`, issued in Contentful under the same space). Don't set these in the production deploy workflow's secrets — doing so publishes draft/unpublished content to the live public site.

## Content model

The build reads the `contentful_collections` list in [_config.yml](_config.yml) and generates one page per Contentful entry per collection — this is the extension point for adapting the template to a new site:

```yaml
contentful_collections:
  - content_type: post
    layout: post
    dir: posts
  - content_type: page
    layout: page
    dir: ""
    nav: true
```

- `content_type` — the Contentful content type id to fetch
- `layout` — which layout in [_layouts/](_layouts/) renders the page
- `dir` — URL path prefix; `posts` builds `/posts/<slug>/`, `""` builds pages at the site root (`/<slug>/`)
- `nav` — optional; set `true` to list this collection's pages in the site nav (see `_layouts/default.html`)
- `order` — optional; a [Contentful CDA order value](https://www.contentful.com/developers/docs/references/content-delivery-api/#/reference/search-parameters/order) (e.g. `fields.publishDate` or `-fields.publishDate`) controlling fetch/display order; defaults to `-sys.updatedAt`

An entry's `slug` field is sanitized into a URL-safe form (lowercased, spaces/punctuation replaced) if it isn't one already — a build warning is logged when this happens, so messy slugs in Contentful are visible without breaking the build.

Every content type is expected to have `slug` and `body` fields; `post` additionally uses `publishDate` for ordering. `title` always comes from that content type's Contentful-configured "Entry title" field (set per content type in Contentful's UI), whatever it's actually named — so a content type whose title field is called something else entirely (e.g. `headline` or `eventName`) works without any template changes, and content types don't need a field literally called `title`. To add a new content type (e.g. a "product" or "event"), add an entry to `contentful_collections` and a matching layout — no changes to the generator plugin are needed.

Some content types are only ever referenced from other entries and never need a page/URL of their own (e.g. an "author" or "manufacturer" linked from posts/products). List those under `contentful_data_collections` instead, and they're fetched into `site.data.<name>` rather than generating pages:

```yaml
contentful_data_collections:
  - content_type: author
    name: authors
```

## Using this repo as a template

This repo is a GitHub template repo. To start a new site from it:

1. Click "Use this template" on GitHub (or `gh repo create <new-repo> --template pettersuul/github-pages-contentful`) to create your new repo.
2. Update `title`/`description` in `_config.yml`, and adjust `contentful_collections` to match the new site's content types.
3. Point it at a new Contentful space via `.env` locally and the three Actions secrets in the new repo (see Setup above).

## Commands

- `bundle exec jekyll serve` — run the local dev server at `http://localhost:4000` (reads `.env` via the `dotenv` gem)
- `bundle exec jekyll build` — build the static site into `_site/`
- `bundle exec jekyll build --trace` — build with full backtraces on plugin errors
