require "cgi"
require "rich_text_renderer"

module ContentfulJekyll
  # Renders an embedded entry (block or inline) inside a Rich Text field as
  # its title, since the template can't know a site's content model or CSS
  # in advance. Sites that want richer embeds can swap this out.
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

    # Same displayField-driven title resolution as EntrySerializer#flatten_fields
    # (this file has no direct dependency on that class -- the display-field
    # map is threaded through via `mappings`, the same Hash the gem already
    # passes to every renderer it instantiates -- see EntrySerializer#rich_text_renderer).
    # Falls back to a literal `title`/`name` field if display_fields wasn't
    # provided (e.g. a site overriding RICH_TEXT_MAPPINGS without it).
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

  # "entry-hyperlink" (link text to a Contentful entry, as opposed to
  # "hyperlink"'s external URL) and "resource-hyperlink" (the same, for a
  # cross-space entry) are both unmapped by rich_text_renderer. Resolving
  # the linked entry's actual generated page URL isn't possible from
  # here -- this renderer has no knowledge of this site's URL scheme --
  # so the link text renders without a working href rather than crashing
  # the build. Sites that need the real link should override this mapping.
  class EntryHyperlinkRenderer < RichTextRenderer::BaseBlockRenderer
    def render(node)
      "<span class=\"entry-hyperlink\">#{render_content(node)}</span>"
    end
  end

  # The extension point for customizing Rich Text markup: swap any value
  # here to change how that node/mark type renders, or add a key for a
  # node/mark type this template doesn't already handle. Checked against
  # the canonical BLOCKS/INLINES/MARKS lists in @contentful/rich-text-types
  # -- rich_text_renderer's own defaults cover everything except the three
  # entries added here. embedded-resource-block/embedded-resource-inline
  # (a newer, rarer, more complex feature -- cross-app/cross-space embeds)
  # are deliberately left unmapped and will raise a build error, the same
  # as any other genuinely unmapped node/mark type.
  RICH_TEXT_MAPPINGS = {
    "embedded-entry-block" => EmbeddedEntryBlockRenderer,
    "embedded-entry-inline" => EmbeddedEntryInlineRenderer,
    "strikethrough" => StrikethroughRenderer,
    "entry-hyperlink" => EntryHyperlinkRenderer,
    "resource-hyperlink" => EntryHyperlinkRenderer
  }.freeze
end
