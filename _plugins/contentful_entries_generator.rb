require "set"
require "contentful"
require_relative "contentful_client"
require_relative "contentful_locales"
require_relative "contentful_serializer"

module ContentfulJekyll
  # Jekyll::Generator that reads contentful_collections/
  # contentful_data_collections from _config.yml and turns entries into
  # generated pages or site.data. See CLAUDE.md; entry conversion lives in
  # EntrySerializer, locale resolution in contentful_locales.rb.
  class EntriesGenerator < Jekyll::Generator
    safe true
    priority :high

    LOG_TAG = "Contentful:"

    # CDA hard limits: 1000 entries per request, include up to 10 levels of links.
    MAX_PAGE_SIZE = 1000
    INCLUDE_DEPTH = 10

    # Per-collection/locale constants, computed once in fetch_collection
    # and passed as one object to build_page instead of growing its param list.
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
      # Seeded with every existing static page's URL, so a Contentful
      # entry colliding with one (e.g. a blank slug on dir: "" -> "/")
      # gets a specific warning naming the entry, not just Jekyll's
      # generic unnamed "destination shared by multiple files" one.
      @built_dirs = Set.new(site.pages.map(&:url))

      collections = site.config["contentful_collections"] || []
      data_collections = site.config["contentful_data_collections"] || []

      ContentfulJekyll.each_locale(site.config["contentful_locales"]) do |locale|
        # Fresh EntrySerializer per locale, so its memoization cache never
        # mixes translations across locales.
        @serializer = EntrySerializer.new(site, display_fields, entry_depth)

        collections.each { |collection| fetch_collection(site, client, collection, locale) }
        data_collections.each { |collection| fetch_data_collection(site, client, collection, locale) }
      end
    end

    private

    # Maps content_type id -> snake_cased displayField name, so page.title
    # always resolves correctly regardless of the field's real name.
    # Fetched once, not per locale (schemas aren't locale-specific).
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

    # Homepage section heading: explicit `label` (a string, or a Hash
    # keyed by locale code, mirroring `dir`), else a humanized content_type
    # (e.g. "newsArticle" -> "News Article"). Unlike dir_for, falls back
    # instead of raising -- an untranslated heading isn't a broken URL.
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

    # Pages through a Contentful::Array result via #next_page, which
    # reuses the original query.
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
      # Generic alias for the social preview image field (see
      # _includes/seo.html), since content types name it differently.
      # Defaults to "image"; nil if absent, same as any other field.
      page.data["social_image"] = page.data[context.image_field]

      page
    end

    # Sanitizes a slug into a URL-safe form via Jekyll's own slugify (same
    # normalization as post permalinks).
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
