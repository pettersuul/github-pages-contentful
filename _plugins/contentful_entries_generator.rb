require "cgi"
require "set"
require_relative "contentful_client"
require "rich_text_renderer"

module ContentfulJekyll
  # Renders an embedded entry (block or inline) inside a Rich Text field as
  # its title/name, since the template can't know a site's content model or
  # CSS in advance. Sites that want richer embeds can swap this out.
  class EmbeddedEntryBlockRenderer < RichTextRenderer::BaseNodeRenderer
    def render(node)
      wrap("div", node)
    end

    private

    def wrap(tag, node)
      entry = node["data"]["target"]
      return "" unless entry.respond_to?(:fields)

      title = entry.fields[:title] || entry.fields[:name]
      return "" if title.nil?

      "<#{tag} class=\"embedded-entry\">#{CGI.escapeHTML(title.to_s)}</#{tag}>"
    end
  end

  class EmbeddedEntryInlineRenderer < EmbeddedEntryBlockRenderer
    def render(node)
      wrap("span", node)
    end
  end

  # rich_text_renderer's own DEFAULT_MAPPINGS covers every Rich Text mark
  # except "strikethrough" -- without this, any entry using that mark (a
  # standard formatting option in Contentful's own Rich Text editor) fails
  # the whole build.
  class StrikethroughRenderer < RichTextRenderer::BaseInlineRenderer
    protected

    def render_tag
      "s"
    end
  end

  RICH_TEXT_MAPPINGS = {
    "embedded-entry-block" => EmbeddedEntryBlockRenderer,
    "embedded-entry-inline" => EmbeddedEntryInlineRenderer,
    "strikethrough" => StrikethroughRenderer
  }.freeze

  class EntriesGenerator < Jekyll::Generator
    safe true
    priority :high

    # CDA hard limits: 1000 entries per request, include up to 10 levels of links.
    MAX_PAGE_SIZE = 1000
    INCLUDE_DEPTH = 10

    # How deep a linked entry's own fields get flattened before falling back
    # to an {id, link_type} stub, to bound build output on heavily
    # cross-referenced content models (see CLAUDE.md).
    MAX_ENTRY_DEPTH = 2

    def generate(site)
      client = ContentfulClient.build

      if client.nil?
        token_var = ContentfulClient.preview? ? "CONTENTFUL_PREVIEW_ACCESS_TOKEN" : "CONTENTFUL_ACCESS_TOKEN"
        Jekyll.logger.warn "Contentful:", "CONTENTFUL_SPACE_ID / #{token_var} not set, skipping content fetch"
        return
      end

      @display_fields = fetch_display_fields(client)
      @built_dirs = Set.new
      @entry_cache = {}

      collections = site.config["contentful_collections"] || []

      collections.each do |collection|
        fetch_collection(site, client, collection)
      end

      data_collections = site.config["contentful_data_collections"] || []

      data_collections.each do |collection|
        fetch_data_collection(site, client, collection)
      end
    end

    private

    # Maps content_type id -> snake_cased field name of Contentful's own
    # "Entry title" setting (a content type's displayField). page.title
    # (and a linked/data-collection entry's own "title") always comes
    # from this field, whatever it's actually named (e.g. `headline` or
    # `eventName`) -- see flatten_fields below. There's no need for a
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
      each_entry(client, entries_query(collection)) do |entry|
        site.pages << build_page(site, entry, collection)
      end
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
        entries << serialize_entry(entry, 0)
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

    def build_page(site, entry, collection)
      dir = [collection["dir"], sanitized_slug(entry)].compact.reject(&:empty?).join("/")

      unless @built_dirs.add?(dir)
        Jekyll.logger.warn "Contentful:", "multiple entries produced the URL \"/#{dir}/\" (entry #{entry.sys[:id]} included) -- only the last one fetched will survive in the build output"
      end

      body_field = (collection["body_field"] || "body").to_sym

      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")
      page.content = render_body(site, entry.fields[body_field])
      page.data["layout"] = collection["layout"]
      page.data["nav"] = true if collection["nav"]
      page.data.merge!(flatten_fields(entry, 0, skip: [body_field]))

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

    # `body` can arrive as a Rich Text document (Hash), a plain/Markdown
    # string, or nil. Generated pages are named "index.html", which never
    # matches Jekyll's extension-based markdown_ext list, so neither case
    # would otherwise be converted automatically -- both are rendered to
    # HTML explicitly here.
    def render_body(site, value)
      case value
      when Hash
        rich_text_renderer.render(value)
      when nil
        ""
      else
        markdown_converter(site).convert(value.to_s)
      end
    end

    def rich_text_renderer
      @rich_text_renderer ||= RichTextRenderer::Renderer.new(RICH_TEXT_MAPPINGS)
    end

    def markdown_converter(site)
      @markdown_converter ||= site.find_converter_instance(Jekyll::Converters::Markdown)
    end

    # Recursively converts SDK objects (Contentful::Asset, Contentful::Entry,
    # Contentful::Link, arrays of them) into plain Hashes/Strings that Liquid
    # can render, since Liquid can't call methods like `.file.url` or
    # `.fields[...]` on the raw contentful.rb objects.
    def serialize_field(value, depth = 0)
      case value
      when Contentful::Asset
        serialize_asset(value)
      when Contentful::Entry
        depth >= MAX_ENTRY_DEPTH ? reference_stub(value.sys[:id], "Entry") : serialize_entry(value, depth)
      when Contentful::Link
        reference_stub(value.id, value.link_type)
      when Array
        value.map { |item| serialize_field(item, depth) }
      else
        value
      end
    end

    def serialize_asset(asset)
      file = asset.fields[:file]

      {
        "url" => file.nil? ? nil : absolute_url(file.url),
        "content_type" => file&.content_type,
        "title" => asset.fields[:title],
        "description" => asset.fields[:description]
      }
    end

    # Flattens a linked entry's fields the same way build_page flattens
    # top-level fields, so `{{ page.author.title }}` works directly.
    # Memoized per (entry, depth): the same entry can be linked from many
    # pages (e.g. a shared "author"), and Contentful's `includes` list is
    # already deduplicated -- no need to re-flatten it once per occurrence.
    # The resulting Hash is shared by reference across those occurrences;
    # fine since nothing downstream mutates it, only reads it in Liquid.
    def serialize_entry(entry, depth)
      @entry_cache[[entry.sys[:id], depth]] ||= { "id" => entry.sys[:id], "content_type" => entry.sys[:content_type]&.id }
        .merge(flatten_fields(entry, depth + 1))
    end

    # Shared by build_page (top-level page fields) and serialize_entry
    # (a linked entry's own fields) so the flattening rule lives in one place.
    def flatten_fields(entry, depth, skip: [])
      data = entry.fields.each_with_object({}) do |(name, value), data|
        next if skip.include?(name)

        data[name.to_s] = serialize_field(value, depth)
      end

      display_field = @display_fields[entry.sys[:content_type]&.id]
      data["title"] = data[display_field] if display_field

      data
    end

    def reference_stub(id, link_type)
      { "id" => id, "link_type" => link_type }
    end

    # Contentful asset URLs are protocol-relative ("//images.ctfassets.net/...").
    def absolute_url(url)
      url.start_with?("//") ? "https:#{url}" : url
    end
  end
end
