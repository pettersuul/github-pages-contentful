require "cgi"
require "rich_text_renderer"

module ContentfulJekyll
  # Renders an embedded entry as its title. Swap out for richer embeds.
  class EmbeddedEntryBlockRenderer < RichTextRenderer::BaseNodeRenderer
    def render(node)
      wrap("div", node)
    end

    private

    def wrap(tag, node)
      entry = node["data"]["target"]
      return "" unless entry.respond_to?(:fields)

      title = title_for(entry)
      return "" if title.nil?

      "<#{tag} class=\"embedded-entry\">#{CGI.escapeHTML(title.to_s)}</#{tag}>"
    end

    # displayField-driven title, threaded in via mappings[:display_fields]
    # (see EntrySerializer#rich_text_renderer) so this file doesn't depend
    # on EntrySerializer directly. Falls back to a literal title/name field
    # if that key is missing.
    def title_for(entry)
      display_fields = mappings[:display_fields]
      display_field = display_fields && display_fields[entry.sys[:content_type]&.id]
      return entry.fields[display_field.to_sym] if display_field

      entry.fields[:title] || entry.fields[:name]
    end
  end

  class EmbeddedEntryInlineRenderer < EmbeddedEntryBlockRenderer
    def render(node)
      wrap("span", node)
    end
  end

  # DEFAULT_MAPPINGS has no "strikethrough" -- without this, any entry
  # using that mark fails the build.
  class StrikethroughRenderer < RichTextRenderer::BaseInlineRenderer
    protected

    def render_tag
      "s"
    end
  end

  # entry-hyperlink/resource-hyperlink are unmapped by rich_text_renderer.
  # Renders link text only, no href -- this renderer has no knowledge of
  # the site's URL scheme. Override to resolve a real link.
  class EntryHyperlinkRenderer < RichTextRenderer::BaseBlockRenderer
    def render(node)
      "<span class=\"entry-hyperlink\">#{render_content(node)}</span>"
    end
  end

  # Extension point: override a key to change markup, or add one for an
  # unhandled node/mark type. Covers every gap in rich_text_renderer's
  # defaults (checked against @contentful/rich-text-types' BLOCKS/INLINES/
  # MARKS) except embedded-resource-block/-inline, left unmapped on
  # purpose -- raises a build error like any other unhandled type.
  RICH_TEXT_MAPPINGS = {
    "embedded-entry-block" => EmbeddedEntryBlockRenderer,
    "embedded-entry-inline" => EmbeddedEntryInlineRenderer,
    "strikethrough" => StrikethroughRenderer,
    "entry-hyperlink" => EntryHyperlinkRenderer,
    "resource-hyperlink" => EntryHyperlinkRenderer
  }.freeze
end
