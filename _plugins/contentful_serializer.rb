require "contentful"
require_relative "contentful_rich_text"

module ContentfulJekyll
  # Turns a Contentful::Entry into Jekyll-usable data: a flattened field
  # Hash plus rendered body HTML. Pure data transformation, kept separate
  # from EntriesGenerator's build lifecycle (fetching, warnings).
  class EntrySerializer
    # Default recursion depth for flattening linked entries before
    # degrading to a stub. Override via _config.yml's contentful_entry_depth.
    DEFAULT_ENTRY_DEPTH = 2

    # display_fields: content_type id -> snake_cased displayField name
    # (see #flatten_fields).
    def initialize(site, display_fields, max_entry_depth = DEFAULT_ENTRY_DEPTH)
      @site = site
      @display_fields = display_fields
      @max_entry_depth = max_entry_depth
      @entry_cache = {}
    end

    # value: a Rich Text document (Hash), a plain/Markdown string, or nil.
    # Generated pages are named "index.html", which Jekyll's markdown_ext
    # never auto-converts, so both cases are rendered explicitly here.
    def render_body(value)
      case value
      when Hash
        rich_text_renderer.render(value)
      when nil
        ""
      else
        markdown_converter.convert(value.to_s)
      end
    end

    # Flattens entry fields (except `skip`) to a snake_cased Hash. "title"
    # always comes from the content type's displayField, read straight
    # from entry.fields so it's correct even if displayField == skip.
    def flatten_fields(entry, depth, skip: [])
      data = entry.fields.each_with_object({}) do |(name, value), data|
        next if skip.include?(name)

        data[name.to_s] = serialize_field(value, depth)
      end

      display_field = @display_fields[entry.sys[:content_type]&.id]
      data["title"] = serialize_field(entry.fields[display_field.to_sym], depth) if display_field

      data
    end

    # Flattens a linked entry like #flatten_fields, so `page.author.title`
    # works directly. Memoized per (entry id, depth), since Contentful's
    # `includes` is already deduplicated. Frozen: the Hash is shared by
    # reference across occurrences and nothing downstream should mutate it.
    def serialize_entry(entry, depth)
      @entry_cache[[entry.sys[:id], depth]] ||= { "id" => entry.sys[:id], "content_type" => entry.sys[:content_type]&.id }
        .merge(flatten_fields(entry, depth + 1)).freeze
    end

    private

    # Recursively converts SDK objects into plain Hashes/Strings Liquid can
    # render (Liquid can't call `.file.url`/`.fields[...]` on raw
    # contentful.rb objects).
    def serialize_field(value, depth = 0)
      case value
      when Contentful::Asset
        serialize_asset(value)
      when Contentful::Entry
        depth >= @max_entry_depth ? reference_stub(value.sys[:id], "Entry") : serialize_entry(value, depth)
      when Contentful::Link
        reference_stub(value.id, value.link_type)
      when Array
        value.map { |item| serialize_field(item, depth) }
      else
        value
      end
    end

    # Contentful::File only defines methods for keys present in the raw
    # JSON -- an unprocessed asset (e.g. a draft via CONTENTFUL_PREVIEW)
    # has no `url` key, so `file.url` raises NoMethodError, not nil
    # (`file&.url` doesn't help). #safe_field guards every dynamic
    # Contentful::File method read here.
    def serialize_asset(asset)
      file = asset.fields[:file]
      url = safe_field(file, :url)
      # `details` is a plain Hash, not a dynamic object -- `["image"]` is
      # just nil for a non-image asset or one still processing.
      image_details = safe_field(file, :details)&.[]("image")

      {
        "url" => url.nil? ? nil : absolute_url(url),
        "content_type" => safe_field(file, :content_type),
        "title" => asset.fields[:title],
        "description" => asset.fields[:description],
        "width" => image_details && image_details["width"],
        "height" => image_details && image_details["height"]
      }
    end

    def safe_field(object, method)
      object.respond_to?(method) ? object.public_send(method) : nil
    end

    def reference_stub(id, link_type)
      { "id" => id, "link_type" => link_type }
    end

    # Contentful asset URLs are protocol-relative ("//images.ctfassets.net/...").
    def absolute_url(url)
      url.start_with?("//") ? "https:#{url}" : url
    end

    def rich_text_renderer
      @rich_text_renderer ||= RichTextRenderer::Renderer.new(RICH_TEXT_MAPPINGS.merge(display_fields: @display_fields))
    end

    def markdown_converter
      @markdown_converter ||= @site.find_converter_instance(Jekyll::Converters::Markdown)
    end
  end
end
