require "contentful"
require_relative "contentful_rich_text"

module ContentfulJekyll
  # Turns a Contentful::Entry into Jekyll-usable data: a flattened field
  # Hash for page.data/site.data, plus rendered HTML for a body field.
  # This is a pure data transformation with its own state (a display-field
  # lookup, entry memoization) applied identically whether the entry is
  # a top-level generated page, a linked reference, or a data-only
  # collection entry -- kept separate from EntriesGenerator's Jekyll build
  # lifecycle (fetching pages, writing warnings) for that reason.
  class EntrySerializer
    # Default for how deep a linked entry's own fields get flattened before
    # falling back to an {id, link_type} stub, to bound build output on
    # heavily cross-referenced content models -- overridable per site via
    # _config.yml's contentful_entry_depth (see CLAUDE.md).
    DEFAULT_ENTRY_DEPTH = 2

    # display_fields maps content_type id -> snake_cased field name of
    # that content type's Contentful "Entry title" setting (its
    # displayField) -- see #flatten_fields.
    def initialize(site, display_fields, max_entry_depth = DEFAULT_ENTRY_DEPTH)
      @site = site
      @display_fields = display_fields
      @max_entry_depth = max_entry_depth
      @entry_cache = {}
    end

    # `value` can arrive as a Rich Text document (Hash), a plain/Markdown
    # string, or nil. Generated pages are named "index.html", which never
    # matches Jekyll's extension-based markdown_ext list, so neither case
    # would otherwise be converted automatically -- both are rendered to
    # HTML explicitly here.
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

    # Flattens every field on an entry (other than any in `skip`, e.g. the
    # body field) onto a plain Hash keyed by snake_cased field name, and
    # always sets "title" from the content type's displayField (see
    # #initialize) -- read straight from entry.fields, not from the Hash
    # being built, so it's correct even when the displayField happens to
    # be the same field passed in `skip`.
    def flatten_fields(entry, depth, skip: [])
      data = entry.fields.each_with_object({}) do |(name, value), data|
        next if skip.include?(name)

        data[name.to_s] = serialize_field(value, depth)
      end

      display_field = @display_fields[entry.sys[:content_type]&.id]
      data["title"] = serialize_field(entry.fields[display_field.to_sym], depth) if display_field

      data
    end

    # Flattens a linked entry's fields the same way #flatten_fields
    # flattens a top-level page's fields, so `{{ page.author.title }}`
    # works directly. Memoized per (entry, depth): the same entry can be
    # linked from many pages (e.g. a shared "author"), and Contentful's
    # `includes` list is already deduplicated -- no need to re-flatten it
    # once per occurrence. The resulting Hash is shared by reference
    # across those occurrences, so it's frozen: nothing downstream should
    # mutate it (only read it in Liquid), and freezing turns that
    # assumption into an enforced error instead of silent cross-page
    # corruption if it's ever violated.
    def serialize_entry(entry, depth)
      @entry_cache[[entry.sys[:id], depth]] ||= { "id" => entry.sys[:id], "content_type" => entry.sys[:content_type]&.id }
        .merge(flatten_fields(entry, depth + 1)).freeze
    end

    private

    # Recursively converts SDK objects (Contentful::Asset, Contentful::Entry,
    # Contentful::Link, arrays of them) into plain Hashes/Strings that Liquid
    # can render, since Liquid can't call methods like `.file.url` or
    # `.fields[...]` on the raw contentful.rb objects.
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

    # `Contentful::File` only defines a method for each key actually present
    # in the raw JSON (contentful.rb's own `define_fields!`) -- an asset
    # that hasn't finished processing yet (e.g. linked from a draft entry,
    # fetched via CONTENTFUL_PREVIEW) has no "url" key at all yet, so
    # `file.url` is a genuinely undefined method, not nil; `file&.url`
    # doesn't help since `&.` only guards a nil receiver, not an undefined
    # method on a real one. Confirmed via a synthetic Contentful::File
    # missing #url: raises NoMethodError, doesn't return nil.
    def serialize_asset(asset)
      file = asset.fields[:file]
      url = file.respond_to?(:url) ? file.url : nil

      {
        "url" => url.nil? ? nil : absolute_url(url),
        "content_type" => file.respond_to?(:content_type) ? file.content_type : nil,
        "title" => asset.fields[:title],
        "description" => asset.fields[:description]
      }
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
