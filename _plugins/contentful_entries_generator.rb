require "cgi"
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

  RICH_TEXT_MAPPINGS = {
    "embedded-entry-block" => EmbeddedEntryBlockRenderer,
    "embedded-entry-inline" => EmbeddedEntryInlineRenderer
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
        Jekyll.logger.warn "Contentful:", "CONTENTFUL_SPACE_ID / CONTENTFUL_ACCESS_TOKEN not set, skipping content fetch"
        return
      end

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

    def entries_query(collection)
      {
        content_type: collection["content_type"],
        order: "-sys.updatedAt",
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
      entries = []

      each_entry(client, entries_query(collection)) do |entry|
        entries << serialize_entry(entry, 0)
      end

      site.data[collection["name"]] = entries
    end

    # Loops through every page of entries for a query, following
    # Contentful::Array#next_page (which reuses the original query, so
    # content_type/order/include all carry forward automatically).
    def each_entry(client, query)
      page = client.entries(query)

      loop do
        page.each { |entry| yield entry }
        break if page.skip.to_i + page.items.size >= page.total.to_i

        page = page.next_page(client)
        break unless page
      end
    end

    def build_page(site, entry, collection)
      dir = [collection["dir"], entry.fields[:slug]].reject { |part| part.nil? || part.to_s.empty? }.join("/")

      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")
      page.content = render_body(site, entry.fields[:body])
      page.data["layout"] = collection["layout"]

      entry.fields.each do |name, value|
        next if name == :body

        page.data[name.to_s] = serialize_field(value)
      end

      page
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
      site.find_converter_instance(Jekyll::Converters::Markdown)
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
    def serialize_entry(entry, depth)
      data = { "id" => entry.sys[:id], "content_type" => entry.sys[:content_type]&.id }

      entry.fields.each do |name, value|
        data[name.to_s] = serialize_field(value, depth + 1)
      end

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
