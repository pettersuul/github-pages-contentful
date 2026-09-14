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

    def generate(site)
      client = ContentfulClient.build

      if client.nil?
        token_var = ContentfulClient.preview? ? "CONTENTFUL_PREVIEW_ACCESS_TOKEN" : "CONTENTFUL_ACCESS_TOKEN"
        Jekyll.logger.warn "Contentful:", "CONTENTFUL_SPACE_ID / #{token_var} not set, skipping content fetch"
        return
      end

      entry_depth = site.config["contentful_entry_depth"] || EntrySerializer::DEFAULT_ENTRY_DEPTH
      @serializer = EntrySerializer.new(site, fetch_display_fields(client), entry_depth)
      @built_dirs = Set.new

      collections = site.config["contentful_collections"] || []
      collections.each { |collection| fetch_collection(site, client, collection) }

      data_collections = site.config["contentful_data_collections"] || []
      data_collections.each { |collection| fetch_data_collection(site, client, collection) }
    end

    private

    # Maps content_type id -> snake_cased field name of Contentful's own
    # "Entry title" setting (a content type's displayField), passed to
    # EntrySerializer so page.title (and a linked/data-collection entry's
    # own "title") always comes from that field, whatever it's actually
    # named (e.g. `headline` or `eventName`) -- there's no need for a
    # content type to have a field literally called `title`.
    def fetch_display_fields(client)
      fields = {}

      each_page(client.content_types(limit: MAX_PAGE_SIZE), client) do |content_type|
        next if content_type.display_field.nil?

        fields[content_type.id] = Contentful::Support.snakify(content_type.display_field)
      end

      fields
    end

    def entries_query(collection)
      {
        content_type: collection["content_type"],
        order: collection["order"] || "-sys.updatedAt",
        include: INCLUDE_DEPTH,
        limit: MAX_PAGE_SIZE
      }
    end

    def fetch_collection(site, client, collection)
      body_field = (collection["body_field"] || "body").to_sym
      home_label = home_label_for(collection) if collection["home"]

      each_entry(client, entries_query(collection)) do |entry|
        site.pages << build_page(site, entry, collection, body_field, home_label)
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
    def fetch_data_collection(site, client, collection)
      name = collection["name"]

      if site.data.key?(name)
        Jekyll.logger.warn "Contentful:", "site.data.#{name} already exists (e.g. from a _data/#{name}.* file) and will be overwritten by the '#{collection["content_type"]}' data collection"
      end

      entries = []

      each_entry(client, entries_query(collection)) do |entry|
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

    def build_page(site, entry, collection, body_field, home_label)
      dir = [collection["dir"], sanitized_slug(entry)].compact.reject { |part| part.to_s.empty? }.join("/")

      unless @built_dirs.add?(dir)
        Jekyll.logger.warn "Contentful:", "multiple entries produced the URL \"/#{dir}/\" (entry #{entry.sys[:id]} included) -- only the last one fetched will survive in the build output"
      end

      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")
      page.content = @serializer.render_body(entry.fields[body_field])
      page.data["layout"] = collection["layout"]
      page.data["nav"] = true if collection["nav"]
      page.data["home_label"] = home_label if home_label
      page.data.merge!(@serializer.flatten_fields(entry, 0, skip: [body_field]))

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
        Jekyll.logger.warn "Contentful:", "slug \"#{raw_slug}\" (entry #{entry.sys[:id]}) isn't URL-safe, using \"#{slug}\" instead"
      end

      slug
    end
  end
end
