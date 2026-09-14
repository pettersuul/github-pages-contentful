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

Without a `.env` (or those secrets in CI), the build still succeeds — it just generates zero Contentful-backed pages, logging a warning instead of failing.

### Previewing draft content

To build against draft (unpublished) content instead of only published entries, set `CONTENTFUL_PREVIEW=true` and `CONTENTFUL_PREVIEW_ACCESS_TOKEN` (a separate token from your CDA `CONTENTFUL_ACCESS_TOKEN`, issued in Contentful under the same space). **Don't** set these in the production deploy workflow's secrets — doing so publishes draft/unpublished content to the live public site.

## Content model

The build reads the `contentful_collections` list in [_config.yml](_config.yml) and generates one page per Contentful entry per collection — this is the extension point for adapting the template to a new site:

```yaml
contentful_collections:
  - content_type: post
    layout: post
    dir: posts
    home: true
  - content_type: page
    layout: page
    dir: ""
    nav: true
```

| Key | Required | Meaning |
| --- | --- | --- |
| `content_type` | yes | The Contentful content type id to fetch. |
| `layout` | yes | Which layout in [_layouts/](_layouts/) renders the page. |
| `dir` | yes | URL path prefix; `posts` builds `/posts/<slug>/`, `""` builds pages at the site root (`/<slug>/`). |
| `nav` | no | `true` lists this collection's pages in the site nav (see `_layouts/default.html`). |
| `home` | no | `true` lists this collection's pages in a section on the homepage (see `index.html`). Only works with a non-empty `dir` — a no-op on a `dir: ""` collection. |
| `order` | no | A [Contentful CDA order value](https://www.contentful.com/developers/docs/references/content-delivery-api/#/reference/search-parameters/order) (e.g. `fields.publishDate` or `-fields.publishDate`) controlling fetch/display order; defaults to `-sys.updatedAt`. |
| `body_field` | no | The field to render as page content, if not `body`. A field literally named `content` collides with Jekyll's own reserved `page.content`/`{{ content }}` and is otherwise unreachable, so this is the only way to use such a field as the page body. |

Every content type needs a `slug` field and a body field (`body` by default — see `body_field` above); `post` additionally uses `publishDate` for ordering. `title` is never a literal field requirement: it always comes from that content type's Contentful-configured "Entry title" field (set per content type in Contentful's UI), whatever it's actually named — so a content type titled by, say, `headline` or `eventName` works without any template changes.

An entry's `slug` field is sanitized into a URL-safe form (lowercased, spaces/punctuation replaced) if it isn't one already, with a build warning logged when this happens — so messy slugs in Contentful stay visible without breaking the build.

To add a new content type (e.g. a "product" or "event"), add an entry to `contentful_collections` and a matching layout — no changes to the generator plugin are needed.

### Data-only collections

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
