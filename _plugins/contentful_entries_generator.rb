require "set"
require "contentful"
require_relative "contentful_client"
require_relative "contentful_serializer"

module ContentfulJekyll
  # A Jekyll::Generator that runs during the build, iterates the
  # contentful_collections/contentful_data_collections lists in _config.yml,
  # fetches matching entries from Contentful, and turns each one into either
  # a generated page (Jekyll::PageWithoutAFile) or a site.data entry. See
  # CLAUDE.md for the full picture; entry-to-Jekyll-data conversion itself
  # lives in EntrySerializer, not here.
  class EntriesGenerator < Jekyll::Generator
    safe true
    priority :high

    # CDA hard limits: 1000 entries per request, include up to 10 levels of links.
    MAX_PAGE_SIZE = 1000
    INCLUDE_DEPTH = 10

    # code: the Contentful locale code to query (nil -> no `locale` param at
    # all, letting the CDA fall back to the space's own default locale --
    # the single-locale/legacy path). url_prefix/data_suffix: nil for the
    # primary locale (today's exact URLs and site.data keys, unprefixed),
    # or the locale code for every other configured locale. See #each_locale.
    # #primary? is the single source of truth for "is this the unprefixed
    # locale" -- every call site checks that, not code/url_prefix directly,
    # so a future one can't accidentally use the wrong signal (they mean
    # different things: code is nil only in the true no-locale-configured
    # pass, but url_prefix/primary? is nil for the *primary* locale even
    # when real locales are configured and code is a real value).
    Locale = Struct.new(:code, :url_prefix, :data_suffix) do
      def primary?
        url_prefix.nil?
      end
    end

    def generate(site)
      client = ContentfulClient.build

      if client.nil?
        token_var = ContentfulClient.preview? ? "CONTENTFUL_PREVIEW_ACCESS_TOKEN" : "CONTENTFUL_ACCESS_TOKEN"
        Jekyll.logger.warn "Contentful:", "CONTENTFUL_SPACE_ID / #{token_var} not set, skipping content fetch"
        return
      end

      display_fields = fetch_display_fields(client)
      entry_depth = site.config["contentful_entry_depth"] || EntrySerializer::DEFAULT_ENTRY_DEPTH
      # Seeded with every already-existing page's URL (static files like
      # index.html, already loaded into site.pages by the time a
      # Generator runs) so a Contentful entry whose computed URL collides
      # with one of them -- e.g. a blank/missing slug on a dir: ""
      # collection producing "/" -- gets this generator's own specific
      # warning, not just Jekyll's generic "destination shared by
      # multiple files" one (which still fires, but doesn't say which
      # entry caused it, and is easy to miss among this template's other
      # routine build warnings).
      @built_dirs = Set.new(site.pages.map(&:url))

      collections = site.config["contentful_collections"] || []
      data_collections = site.config["contentful_data_collections"] || []

      each_locale(site) do |locale|
        # A fresh EntrySerializer per locale, so its entry-memoization cache
        # never mixes up the same Contentful entry's differently-translated
        # field values across locales.
        @serializer = EntrySerializer.new(site, display_fields, entry_depth)

        collections.each { |collection| fetch_collection(site, client, collection, locale) }
        data_collections.each { |collection| fetch_data_collection(site, client, collection, locale) }
      end
    end

    private

    # Yields one Locale per entry in contentful_locales, first = primary
    # (unprefixed URLs/site.data keys, no page.data["locale"]), the rest
    # prefixed with their own code by default. When contentful_locales isn't
    # set at all, yields a single Locale.new(nil, nil, nil) -- every query,
    # URL, and site.data key this produces is byte-identical to a build with
    # no locale support at all. A *configured* single-entry list (e.g.
    # contentful_locales: [nb-NO]) does NOT collapse to that same nil-code
    # path -- it still sends an explicit locale: nb-NO on every query, so a
    # deliberately-named locale is never silently swapped for whatever the
    # Contentful space itself happens to default to.
    #
    # An entry is either a plain locale code ("nb-NO", prefix == code) or a
    # {code:, prefix:} Hash for when the URL/site.data prefix should be
    # something other than the full Contentful locale code -- e.g.
    # {code: nb-NO, prefix: no} for a shorter URL. Explicit rather than
    # automatic (say, deriving "no" from "nb-NO"'s region subtag) because an
    # automatic shortening scheme has a real collision case with no good
    # silent answer: a space with both en-US and en-GB configured can't
    # shorten both to "en".
    def each_locale(site)
      configured = site.config["contentful_locales"]

      if configured.nil?
        yield Locale.new(nil, nil, nil)
        return
      end

      configured.each_with_index do |entry, index|
        code, prefix = locale_code_and_prefix(entry)
        yield index.zero? ? Locale.new(code, nil, nil) : Locale.new(code, prefix, prefix.downcase.tr("-", "_"))
      end
    end

    def locale_code_and_prefix(entry)
      return [entry, entry] unless entry.is_a?(Hash)

      code = entry["code"] || raise("contentful_locales: entry is missing \"code\": #{entry.inspect}")
      prefix = entry.fetch("prefix", code)

      # YAML reads a bare no/yes/on/off as a boolean, not the string it
      # looks like -- exactly the trap a `prefix: no` (Norwegian) would
      # fall into. Almost certainly a mistake, not an intentional
      # true/false prefix, so fail loudly with the fix rather than
      # silently using `code` instead.
      if [true, false].include?(prefix)
        raise "contentful_locales: prefix for #{code} parsed as the boolean #{prefix.inspect}, not a string -- " \
              "quote it in _config.yml (e.g. prefix: \"no\")"
      end

      [code, prefix]
    end

    # Maps content_type id -> snake_cased field name of Contentful's own
    # "Entry title" setting (a content type's displayField), passed to
    # EntrySerializer so page.title (and a linked/data-collection entry's
    # own "title") always comes from that field, whatever it's actually
    # named (e.g. `headline` or `eventName`) -- there's no need for a
    # content type to have a field literally called `title`. Content type
    # schemas (including displayField) aren't locale-specific, so this is
    # fetched once, not per locale.
    def fetch_display_fields(client)
      fields = {}

      each_page(client.content_types(limit: MAX_PAGE_SIZE), client) do |content_type|
        next if content_type.display_field.nil?

        fields[content_type.id] = Contentful::Support.snakify(content_type.display_field)
      end

      fields
    end

    def entries_query(collection, locale)
      query = {
        content_type: collection["content_type"],
        order: collection["order"] || "-sys.updatedAt",
        include: INCLUDE_DEPTH,
        limit: MAX_PAGE_SIZE
      }
      query[:locale] = locale.code if locale.code
      query
    end

    def fetch_collection(site, client, collection, locale)
      body_field = (collection["body_field"] || "body").to_sym
      home_label = home_label_for(collection) if collection["home"]
      collection_dir = dir_for(collection, locale)

      each_entry(client, entries_query(collection, locale)) do |entry|
        site.pages << build_page(site, entry, collection, body_field, home_label, locale, collection_dir)
      end
    end

    # A collection's homepage section heading: an explicit `label`, or a
    # humanized form of its content_type id (e.g. "newsArticle" ->
    # "News Article") via the same snake_casing contentful.rb itself uses
    # for field names, rather than the raw id capitalized as-is.
    def home_label_for(collection)
      collection["label"] || Contentful::Support.snakify(collection["content_type"]).split("_").map(&:capitalize).join(" ")
    end

    # Fetches a content type into site.data.<name> instead of generating a
    # page per entry -- for entries that are only ever linked to from other
    # entries (e.g. authors, manufacturers) and have no page of their own.
    def fetch_data_collection(site, client, collection, locale)
      name = [collection["name"], locale.data_suffix].compact.join("_")

      if site.data.key?(name)
        Jekyll.logger.warn "Contentful:", "site.data.#{name} already exists (e.g. from a _data/#{name}.* file) and will be overwritten by the '#{collection["content_type"]}' data collection"
      end

      entries = []

      each_entry(client, entries_query(collection, locale)) do |entry|
        entries << @serializer.serialize_entry(entry, 0)
      end

      site.data[name] = entries
    end

    def each_entry(client, query)
      each_page(client.entries(query), client) { |entry| yield entry }
    end

    # Loops through every page of a Contentful::Array result (entries,
    # content types, ...), following Contentful::Array#next_page (which
    # reuses the original query, so content_type/order/include all carry
    # forward automatically).
    def each_page(first_page, client)
      page = first_page

      loop do
        page.each { |item| yield item }
        break if page.skip.to_i + page.items.size >= page.total.to_i

        page = page.next_page(client)
        break unless page
      end
    end

    def build_page(site, entry, collection, body_field, home_label, locale, collection_dir)
      dir = [locale.url_prefix, collection_dir, sanitized_slug(entry)].reject { |part| part.to_s.empty? }.join("/")
      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")

      unless @built_dirs.add?(page.url)
        Jekyll.logger.warn "Contentful:", "multiple entries (or an existing site file) produced the URL \"#{page.url}\" (entry #{entry.sys[:id]} included) -- only the last one written will survive in the build output"
      end

      page.content = @serializer.render_body(entry.fields[body_field])
      page.data["layout"] = collection["layout"]
      page.data["nav"] = true if collection["nav"]
      page.data["home_label"] = home_label if home_label
      page.data["locale"] = locale.code unless locale.primary?
      page.data.merge!(@serializer.flatten_fields(entry, 0, skip: [body_field]))

      page
    end

    # A collection's `dir` is usually one string, used for every locale --
    # but the URL path segment itself (unlike the locale-code prefix
    # each_locale already adds) often needs to be a different word per
    # locale (e.g. "produkter" vs "products"). Set `dir` to a Hash keyed
    # by locale code for that; anything else (a plain string, including
    # "") is used as-is regardless of locale, exactly as before this was
    # possible. Resolved once per collection per locale pass (fetch_collection),
    # not per entry -- it can't vary within a single pass.
    def dir_for(collection, locale)
      dir = collection["dir"]
      return dir unless dir.is_a?(Hash)

      return dir[locale.code] if dir.key?(locale.code)

      raise "contentful_collections: dir is a per-locale Hash (#{dir.inspect}) but has no entry for " \
            "#{locale.code.inspect} (content_type: #{collection["content_type"]})" \
            "#{" -- is contentful_locales configured?" if locale.code.nil?}"
    end

    # Content editors will eventually type a slug with spaces, capitals, or
    # other characters that aren't safe verbatim in a URL path. Reuses
    # Jekyll's own slugify (the same normalization Jekyll applies to post
    # filenames/permalinks) rather than leaving a raw field value to become
    # the page's URL unchanged.
    def sanitized_slug(entry)
      raw_slug = entry.fields[:slug]
      return raw_slug if raw_slug.nil?

      slug = Jekyll::Utils.slugify(raw_slug.to_s)

      if slug != raw_slug.to_s
        Jekyll.logger.warn "Contentful:", "slug \"#{raw_slug}\" (entry #{entry.sys[:id]}) isn't URL-safe, using \"#{slug}\" instead"
      end

      slug
    end
  end
end
