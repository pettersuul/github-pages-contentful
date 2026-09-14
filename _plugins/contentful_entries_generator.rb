require "set"
require "contentful"
require_relative "contentful_client"
require_relative "contentful_locales"
require_relative "contentful_serializer"

module ContentfulJekyll
  # A Jekyll::Generator that runs during the build, iterates the
  # contentful_collections/contentful_data_collections lists in _config.yml,
  # fetches matching entries from Contentful, and turns each one into either
  # a generated page (Jekyll::PageWithoutAFile) or a site.data entry. See
  # CLAUDE.md for the full picture; entry-to-Jekyll-data conversion lives in
  # EntrySerializer and locale resolution in contentful_locales.rb, not here.
  class EntriesGenerator < Jekyll::Generator
    safe true
    priority :high

    LOG_TAG = "Contentful:"

    # CDA hard limits: 1000 entries per request, include up to 10 levels of links.
    MAX_PAGE_SIZE = 1000
    INCLUDE_DEPTH = 10

    # Everything about one contentful_collections entry that's constant
    # across every entry in it for a given locale pass -- computed once in
    # fetch_collection (same reasoning as body_field/home_label/dir being
    # hoisted out of the per-entry loop already) and passed as one object
    # to build_page instead of growing that method's positional params by
    # one every time a new per-collection setting is added.
    CollectionContext = Struct.new(:collection, :locale, :body_field, :home_label, :dir, :image_field, keyword_init: true)

    def generate(site)
      client = ContentfulClient.build

      if client.nil?
        token_var = ContentfulClient.preview? ? "CONTENTFUL_PREVIEW_ACCESS_TOKEN" : "CONTENTFUL_ACCESS_TOKEN"
        Jekyll.logger.warn LOG_TAG, "CONTENTFUL_SPACE_ID / #{token_var} not set, skipping content fetch"
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

      ContentfulJekyll.each_locale(site.config["contentful_locales"]) do |locale|
        # A fresh EntrySerializer per locale, so its entry-memoization cache
        # never mixes up the same Contentful entry's differently-translated
        # field values across locales.
        @serializer = EntrySerializer.new(site, display_fields, entry_depth)

        collections.each { |collection| fetch_collection(site, client, collection, locale) }
        data_collections.each { |collection| fetch_data_collection(site, client, collection, locale) }
      end
    end

    private

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
      context = CollectionContext.new(
        collection: collection,
        locale: locale,
        body_field: (collection["body_field"] || "body").to_sym,
        home_label: (home_label_for(collection, locale) if collection["home"]),
        dir: ContentfulJekyll.dir_for(collection, locale),
        image_field: collection["image_field"] || "image"
      )

      each_entry(client, entries_query(collection, locale)) do |entry|
        site.pages << build_page(site, entry, context)
      end
    end

    # A collection's homepage section heading: an explicit `label` (a plain
    # string, used as-is for every locale, or -- mirroring `dir`'s
    # per-locale Hash escape hatch -- a Hash keyed by locale code for a
    # translated heading per locale), or a humanized form of its
    # content_type id (e.g. "newsArticle" -> "News Article") via the same
    # snake_casing contentful.rb itself uses for field names, rather than
    # the raw id capitalized as-is. Unlike `dir_for`, a locale missing from
    # a `label` Hash falls back to the humanized default rather than
    # raising -- an untranslated heading is a real but non-breaking gap,
    # not a broken URL.
    def home_label_for(collection, locale)
      label = collection["label"]
      label = label[locale.code] if label.is_a?(Hash)

      label || Contentful::Support.snakify(collection["content_type"]).split("_").map(&:capitalize).join(" ")
    end

    # Fetches a content type into site.data.<name> instead of generating a
    # page per entry -- for entries that are only ever linked to from other
    # entries (e.g. authors, manufacturers) and have no page of their own.
    def fetch_data_collection(site, client, collection, locale)
      name = [collection["name"], locale.data_suffix].compact.join("_")

      if site.data.key?(name)
        Jekyll.logger.warn LOG_TAG, "site.data.#{name} already exists (e.g. from a _data/#{name}.* file) and will be overwritten by the '#{collection["content_type"]}' data collection"
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

    def build_page(site, entry, context)
      dir = [context.locale.url_prefix, context.dir, sanitized_slug(entry)].reject { |part| part.to_s.empty? }.join("/")
      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")

      unless @built_dirs.add?(page.url)
        Jekyll.logger.warn LOG_TAG, "multiple entries (or an existing site file) produced the URL \"#{page.url}\" (entry #{entry.sys[:id]} included) -- only the last one written will survive in the build output"
      end

      page.content = @serializer.render_body(entry.fields[context.body_field])
      page.data["layout"] = context.collection["layout"]
      page.data["nav"] = true if context.collection["nav"]
      page.data["home_label"] = context.home_label if context.home_label
      page.data["locale"] = context.locale.code unless context.locale.primary?
      page.data.merge!(@serializer.flatten_fields(entry, 0, skip: [context.body_field]))
      # A generic alias for whatever field holds this collection's social
      # preview image (Open Graph/Twitter Card, see _includes/seo.html),
      # since content types name it differently ("coverImage", "image",
      # "contentImage", ...) -- same body_field/image_field pattern.
      # Defaults to trying "image" (a common convention); harmless if no
      # such field exists (just nil, same as any other absent field).
      page.data["social_image"] = page.data[context.image_field]

      page
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
        Jekyll.logger.warn LOG_TAG, "slug \"#{raw_slug}\" (entry #{entry.sys[:id]}) isn't URL-safe, using \"#{slug}\" instead"
      end

      slug
    end
  end
end
