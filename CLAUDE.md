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

The site pulls its content from Contentful at **build time** rather than storing pages as files in the repo. Five plugin files split that work along its natural seams:

| File | Responsibility |
| --- | --- |
| `_plugins/contentful_client.rb` | Builds the `Contentful::Client` used everywhere else. |
| `_plugins/contentful_locales.rb` | Locale resolution: the `Locale` struct and `.each_locale`/`.dir_for` — pure functions of `_config.yml`'s `contentful_locales`/`dir`, no Jekyll dependency. |
| `_plugins/contentful_rich_text.rb` | Rich Text → HTML rendering rules. The extension point for custom embed/markup. |
| `_plugins/contentful_serializer.rb` | Turns a `Contentful::Entry` into plain Jekyll data (a Hash for `page.data`/`site.data`, plus rendered body HTML). |
| `_plugins/contentful_entries_generator.rb` | The `Jekyll::Generator` that drives the build: reads `_config.yml`, fetches entries, and turns each one into a generated page or a `site.data` entry. |

### Connecting to Contentful

`contentful_client.rb` builds a `Contentful::Client` from `CONTENTFUL_SPACE_ID` / `CONTENTFUL_ACCESS_TOKEN` / `CONTENTFUL_ENVIRONMENT` env vars, returning `nil` if credentials are missing — local builds without a `.env` still succeed, just with no generated pages (`EntriesGenerator` logs a warning and returns early).

Set `CONTENTFUL_PREVIEW=true` to build against draft content instead of only published entries: the client then reads `CONTENTFUL_PREVIEW_ACCESS_TOKEN` (a separate token from the CDA `CONTENTFUL_ACCESS_TOKEN`, issued separately in Contentful) and points at `preview.contentful.com` instead of `cdn.contentful.com`.

### How a page gets built

`EntriesGenerator#generate` (in `contentful_entries_generator.rb`) runs once per build:

1. Build the Contentful client; bail out (with a warning) if credentials are missing.
2. Fetch every content type's `displayField` (see "Title" below) via `client.content_types` — once, not per locale (content type schemas aren't locale-specific).
3. For each configured locale (see "Locales" below; a single pass with no `locale` param at all if `contentful_locales` isn't set), with a fresh `EntrySerializer` per pass:
   - For each entry in `contentful_collections`, fetch its entries and turn each into a `Jekyll::PageWithoutAFile` at `/<dir>/<slug>/` (`dir: ""` → site root; locale-prefixed for a non-primary locale). There are no files on disk for individual entries — they only exist as generated pages during a build.
   - For each entry in `contentful_data_collections`, fetch its entries into `site.data.<name>` instead (see "Data-only collections" below).

To add a new content type, add a `contentful_collections` entry and a matching layout in `_layouts/` — no Ruby changes needed. The default `post` and `page` collections both point at `_layouts/single.html` (`layout: default` + `{% include article.html %}`) since they render identically; give a new collection its own layout file only once it actually needs different markup. A `contentful_collections` entry supports:

| Key | Required | Meaning |
| --- | --- | --- |
| `content_type` | yes | The Contentful content type id to fetch. |
| `layout` | yes | Which layout renders the page. |
| `dir` | yes | URL path prefix (`dir: ""` → site root). |
| `nav` | no | `true` lists this collection's pages in the site nav (see "Homepage & navigation"). |
| `home` | no | `true` groups this collection's pages into a homepage section (see "Homepage & navigation"). |
| `label` | no | Homepage section heading for this collection, if `home` is set. Defaults to a humanized `content_type` (e.g. `newsArticle` → "News Article"). |
| `order` | no | A raw [Contentful CDA order value](https://www.contentful.com/developers/docs/references/content-delivery-api/#/reference/search-parameters/order) (e.g. `-fields.publishDate`); defaults to `-sys.updatedAt`. |
| `body_field` | no | Which field to render as page content, if not `body` (see "Content type conventions" below). |

A top-level `contentful_entry_depth` setting (default 2) controls how deep linked entries get flattened before degrading to a stub — see "Field exposure" below.

Entries are fetched with `include: 10` (resolves up to 10 levels of linked entries — required for the linked-entry flattening described below) and paginated in `MAX_PAGE_SIZE`-sized (1000, the CDA's hard limit) requests until exhausted, via the shared `each_page` loop, so content types with more entries than one page are no longer silently truncated. `each_page` is generic over any Contentful CDA list endpoint (entries, content types, ...), since `Contentful::Array#next_page` dispatches by the resource's own type.

### Content type conventions

Every content type needs a **`slug`** field (used as the URL segment) and a **body field**. Two things `EntriesGenerator` does *not* require a content type to have a literal field for:

- **Body field**: `body` by default; set `body_field` on a `contentful_collections` entry to use a different field name. A real space was found with its body field named `content`, which also collides with Jekyll's own reserved `page.content`/`{{ content }}` and is unreachable any other way — `body_field` is the only way to use such a field as the page body.
- **Title**: `page.title` (and a linked/data-collection entry's own `title`) always comes from that content type's "Entry title" setting — its `displayField` in the CDA, configured per content type in Contentful's UI — not from a literal `title` field. This is fetched once per build (`fetch_display_fields`) and applied in `EntrySerializer#flatten_fields`, reading straight from `entry.fields` rather than from the Hash being built, so it's correct even when the displayField happens to be the same field configured as `body_field`. Content types are free to name their title field anything (e.g. `headline`, `eventName`) with zero template changes.

The default `post` collection additionally uses `publishDate` for ordering and display, and `slug` is sanitized into a URL-safe form (`Jekyll::Utils.slugify` — the same normalization Jekyll uses for post permalinks) if it isn't one already, with a build warning logged when that happens. If two entries produce the same URL (a raw collision, two slugs that sanitize to the same value, or a blank/missing slug on a `dir: ""` collection landing on `"/"`), a build warning names the colliding entry and only the last one written survives in the output — `@built_dirs` (`build_page`, `generate`) is seeded with every already-existing page's URL (including static files like `index.html`) before any Contentful entry is fetched, specifically so this covers a Contentful entry colliding with the site's own static pages, not just with each other. Jekyll's own generic "destination shared by multiple files" conflict warning also fires for this case regardless, but doesn't say which entry caused it and is easy to miss among this template's other routine build warnings.

### Rich Text rendering (`contentful_rich_text.rb`)

A content type's body field (or any linked entry's Rich Text field — see "Known gap" below) can be a Contentful Rich Text document, rendered to HTML via the `rich_text_renderer` gem through `RICH_TEXT_MAPPINGS`. Checked against the canonical `BLOCKS`/`INLINES`/`MARKS` lists in `@contentful/rich-text-types`, the gem's own defaults cover everything except three node/mark types, which this file adds:

- **`embedded-entry-block`/`embedded-entry-inline`** — render as the linked entry's title (same displayField-driven resolution as everywhere else — see "Content type conventions" — threaded in via a `display_fields` key merged into the mappings Hash the gem passes to every renderer it instantiates, since this file has no direct dependency on `EntrySerializer`; falls back to a literal `title`/`name` field if that key isn't present), wrapped in `<div class="embedded-entry">`/`<span class="embedded-entry">`.
- **`strikethrough`** — a standard Contentful Rich Text mark, otherwise missing from the gem entirely and fatal the first time real content uses it. Renders as `<s>`.
- **`entry-hyperlink`/`resource-hyperlink`** — linking text to a Contentful entry (as opposed to `hyperlink`'s external URL). Renders as `<span class="entry-hyperlink">` with no `href`, since resolving the linked entry's actual generated page URL isn't possible from inside the Rich Text renderer — it has no knowledge of this site's URL scheme.

`embedded-resource-block`/`embedded-resource-inline` remain deliberately unmapped (a newer, rarer, more complex feature — cross-app/cross-space embeds) and still raise a build error rather than silently mangling output, same as any other genuinely unmapped node/mark type. Override any key in `RICH_TEXT_MAPPINGS` to change markup, or add one for a node/mark type not listed here.

### Field exposure (`contentful_serializer.rb`)

`EntrySerializer#flatten_fields` copies every field on an entry (other than its body field) onto a plain Hash by its snake_cased field ID (contentful.rb symbolizes field names, e.g. Contentful field `coverImage` → `page.cover_image`) — no allowlist, no Ruby changes needed to reference a new field in a layout. `#serialize_field` converts SDK objects Liquid can't call methods on (`.file.url`, `.fields[...]`) into plain Hashes/Strings:

- **Assets** (`Contentful::Asset`) → `{ "url", "content_type", "title", "description" }`, with `url` rewritten from Contentful's protocol-relative form (`//images.ctfassets.net/...`) to an absolute `https://` URL. Use as `<img src="{{ page.cover_image.url }}">`. An asset that hasn't finished processing yet (e.g. linked from a draft entry via `CONTENTFUL_PREVIEW`) has no `url`/`content_type` key in its raw `file` JSON at all — contentful.rb only defines a method per key actually present — so `serialize_asset` checks `respond_to?` rather than assuming a non-nil `file` always has both (confirmed via a synthetic `Contentful::File` missing `#url`: raises `NoMethodError`, doesn't return `nil`, so `file&.url` alone doesn't help).
- **Linked entries** (`Contentful::Entry`, e.g. a reference field like `author`) → the linked entry's own fields, flattened the same way as `page.data` (so `{{ page.author.title }}` works directly), plus `id` and `content_type`. Memoized per `(entry id, depth)` and frozen — the same entry can be linked from many pages (e.g. a shared "author"), so it's flattened once and the resulting Hash shared by reference; freezing makes "nothing downstream mutates it" an enforced invariant rather than an assumption.
- **Depth capping**: recurses up to `contentful_entry_depth` levels (default `EntrySerializer::DEFAULT_ENTRY_DEPTH`, 2) to bound build output on heavily cross-referenced content models — reconstructing a nested tree from Contentful's flat, deduplicated `includes` list means a shared reference gets fully duplicated per occurrence in the output, so uncapped recursion risks real bloat on content models with wide fan-out (e.g. "related posts"). Beyond that depth, and for any link Contentful didn't resolve at all, an entry degrades to `{ "id", "link_type" }` — the same shape as an unresolved `Contentful::Link` stub. A real site was found needing depth 3 (a `menu` entry linking `page`s which each link their own `subpages`) — raise `contentful_entry_depth` in `_config.yml` for content models with chains like this.
- **Known gap**: this Hash-flattening does not run the Rich Text rendering described above — a linked entry's own Rich Text field (e.g. `page.author.bio`) arrives as the raw string-keyed Rich Text Hash, and any assets/entries embedded inside it remain live, unserialized SDK objects. Only a page's own top-level body field is pre-rendered.

This mirrors how Contentful's own [jekyll-contentful-data-import](https://github.com/contentful/jekyll-contentful-data-import) plugin maps `Contentful::Asset`/`Contentful::Entry`/`Contentful::Link` values (`lib/jekyll-contentful-data-import/mappers/base.rb`), scoped down to just what this template needs (no multi-locale support, no custom per-content-type mappers).

### Homepage & navigation

- **`index.html`** groups generated pages into homepage sections via `page.data["home_label"]`, which `build_page` sets (once per collection, to `label` or a humanized `content_type`) whenever a collection has `home: true`. The template filters `site.pages` for a truthy `home_label` and groups by it (Liquid's `group_by`) — no per-collection loop, no dependence on `dir`.
- **`_layouts/default.html`** builds a nav from every generated page whose collection has `nav: true` set in `_config.yml` (the generator copies that onto `page.data["nav"]`), sorted by title.

Both flags are independent, collection-level, and driven entirely by data set on the page itself (`home_label`, `nav`) rather than by inspecting a page's URL or layout — a collection can be in the nav, the homepage, both, or neither, regardless of its `dir`.

### Data-only collections

A separate `contentful_data_collections` list (each entry: `content_type`, `name`) fetches a content type into `site.data.<name>` instead of generating pages for it — for entries that are only ever linked to from other entries (e.g. authors, manufacturers) and have no page/URL of their own. Each entry is flattened the same way a linked reference is (`EntrySerializer#serialize_entry`), so it comes back with `id`/`content_type` plus its own fields. A build warning is logged if `name` collides with an existing `site.data` key (e.g. a `_data/<name>.yml` file), which it then overwrites.

### Locales (`contentful_locales.rb`)

`ContentfulJekyll.each_locale` yields one `Locale` struct (`code`, `url_prefix`, plus `#primary?` — `url_prefix.nil?` — and `#data_suffix`, always *derived* from `url_prefix`, never stored, so the two can't desync) per entry in the top-level `contentful_locales` config, first = primary. It's a module-level function of that config value alone (not the whole `Jekyll::Site`), same as `.dir_for` below — genuinely Jekyll-independent, unlike everything in `contentful_entries_generator.rb`. When `contentful_locales` is unset entirely, it yields a single `Locale.new(nil, nil)` — every query, URL, and `site.data` key this produces is byte-identical to a build with no locale support at all, which is the whole point: single-locale sites (the common case, and every site this template has been tested against so far) never exercise any of this machinery. A *configured* single-entry list (e.g. `contentful_locales: [nb-NO]`) does **not** collapse to that same path — it still sends an explicit `locale: nb-NO` on every query, so a deliberately named locale can't silently end up fetching whatever the Contentful space itself defaults to instead (verified against the real reinertsen space, whose own CDA default is `en-US`: a single-entry `[nb-NO]` config correctly built Norwegian content, not English).

Every call site checks primary-ness via `locale.primary?`, not `code`/`url_prefix` directly — those two mean different things (`code` is `nil` only in the true no-locale-configured pass; `url_prefix`/`primary?` is `nil` for the primary locale even when real locales are configured and `code` is a real value), so a future call site checking the wrong one would silently apply non-primary logic to the primary locale or vice versa.

With 2+ locales configured, each pass (`EntriesGenerator#generate`):

- Adds `locale: code` to every CDA query (`entries_query`) — the primary locale is queried explicitly too, rather than relying on Contentful's own space-default locale, so the site's chosen primary doesn't silently depend on matching whatever the space happens to have configured as its own default.
- Prefixes generated URLs and `site.data` keys with the locale's prefix, except for the primary locale (`url_prefix`/`data_suffix` are `nil` for it) — see README.md's Locales section for the exact scheme. A `contentful_locales` entry is either a bare code (prefix == code, e.g. `nb-NO`) or a `{code:, prefix:}` Hash for a different one (`.locale_code_and_prefix`) -- deliberately explicit rather than automatically deriving a short prefix from the code's region subtag, since that has a real, silent collision case (a space with both `en-US` and `en-GB` can't both shorten to `en`). `site.data` key suffixes stay valid Liquid dot-notation (`site.data.authors_nb_no`, not `site.data["authors_nb-NO"]`). `.locale_code_and_prefix` fails loudly if `prefix` parsed as a boolean -- YAML reads a bare `no`/`yes`/`on`/`off` as `true`/`false`, not the string it looks like, which is exactly the trap an unquoted `prefix: no` (Norwegian) falls into.
- Sets `page.data["locale"]` to the locale code for every non-primary page (never for the primary locale, matching the `nil` "no locale in play" convention used everywhere else) — this is what `_layouts/default.html`'s nav and `index.html`'s homepage listing use to scope themselves to one locale at a time via `where: "locale", page.locale`, a true no-op when every page's `locale` is `nil`. This relies specifically on **Jekyll's own** `where` filter override (`Jekyll::Filters#where`, via `compare_property_vs_target`'s explicit `when NilClass; return true if property.nil?`), not raw Liquid's `StandardFilters#where` (which has a different, truthy-only nil behavior) — confirmed against both sources and a real build, since the two are easy to conflate. Like `nav`/`home_label`, a Contentful field literally named `locale` on some content type would silently collide and overwrite this (same class of risk noted below in "Field exposure" for `home_label`/body field names).
- Gets its own `EntrySerializer` instance (`generate` constructs a fresh one per locale pass) so the entry-memoization cache (`@entry_cache`, keyed by `(entry id, depth)`) never returns one locale's cached, frozen field values for the same Contentful entry ID fetched under a different locale.

`each_locale`'s URL/data-key prefix only covers the locale code itself. A collection's `dir` can additionally be a Hash keyed by locale code (`ContentfulJekyll.dir_for`, resolved once per collection per locale pass in `fetch_collection` — it can't vary per entry, so it isn't recomputed per entry the way it briefly was) instead of one string, for when the path segment itself needs translating too (e.g. `produkter` vs `products`), not just prefixing — `.dir_for` raises immediately if a configured locale is missing from the Hash, rather than silently building at a wrong/empty path. A locale code has to already exist in the Contentful space (Settings → Locales) before it can be queried — the CDA returns a 400 ("Unknown locale") for one that isn't, with no fallback.

`<html lang>` in `_layouts/default.html` uses `page.locale`, falling back to the top-level `lang` setting in `_config.yml` (defaulting to `"en"` if that's unset too) — `page.locale` is `nil` for every primary-locale page, so without `site.lang` every primary page would get `lang="en"` regardless of what the primary locale actually is. Update `_config.yml`'s `lang` to match if the primary locale isn't English.

A manually-authored per-locale static page (e.g. a localized `nb-NO/index.html`, since `index.html` itself only ever renders the primary locale — see "Homepage & navigation") needs `locale: nb-NO` in its own front matter to match this convention; without it, `page.locale` is `nil` there too and the nav/homepage `where` filters silently scope it as if it were a primary-locale page instead of erroring.

### No RSS/Atom feed (deliberately)

The original scaffold shipped `jekyll-feed` as a default plugin; it's been removed, not fixed. Its bundled feed template assumes blog-post-shaped fields (a plain string `image`, a `date`, etc.) and crashes as soon as a real Contentful field shares one of those names with a different shape — confirmed: pointing it at `site.pages` (via its `feed.collections` config, which does work as a redirect target) crashed outright on a real Product's `image` field, this template's serialized asset Hash, not a plain path. Since this template's entire point is an arbitrary, per-site content model, no field-name convention is safe to assume.

Most sites built from this template won't have blog/news-shaped content anyway (a feed is genuinely useful for chronological, article-like content — a product catalog like the wine space has no real use for one). If a specific site does need a feed, don't reach for `jekyll-feed` — write a small hand-rolled one instead, following the exact pattern `index.html` already demonstrates: loop `site.pages`, filter by whatever flag marks feed-worthy content (mirroring `home`/`nav`), and read only `title`/`url`/`content` (already-rendered HTML, available on any page from anywhere once Jekyll's content-conversion phase has run) — fields every generated page already has, regardless of content type. This was prototyped and verified working end-to-end against both real test spaces before being deliberately left out; ~30 lines, no new architecture needed.

### Why GitHub Actions instead of native GitHub Pages builds

GitHub Pages' built-in Jekyll build runs in "safe mode," which disables custom plugins and network access — incompatible with a generator that calls the Contentful API. Because of this, the site is **not** deployed via GitHub's automatic Jekyll build; instead `.github/workflows/deploy.yml` runs `bundle exec jekyll build` directly (full plugin support) and publishes `_site/` via `actions/deploy-pages`. The GitHub repo's Pages source must be set to "GitHub Actions", not "Deploy from a branch".

Contentful credentials must be present both locally (`.env`, gitignored) and in CI (repo Actions secrets: `CONTENTFUL_SPACE_ID`, `CONTENTFUL_ACCESS_TOKEN`, `CONTENTFUL_ENVIRONMENT`) — the generator silently produces zero posts if they're absent rather than failing the build.
