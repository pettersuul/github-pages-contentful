module ContentfulJekyll
  # code: the Contentful locale code to query (nil -> no `locale` param at
  # all, letting the CDA fall back to the space's own default locale --
  # the single-locale/legacy path). url_prefix: nil for the primary locale
  # (today's exact URLs and site.data keys, unprefixed), or the locale's
  # prefix for every other configured locale. See .each_locale.
  # #primary? is the single source of truth for "is this the unprefixed
  # locale" -- every call site checks that, not code/url_prefix directly,
  # so a future one can't accidentally use the wrong signal (they mean
  # different things: code is nil only in the true no-locale-configured
  # pass, but url_prefix/primary? is nil for the *primary* locale even
  # when real locales are configured and code is a real value).
  Locale = Struct.new(:code, :url_prefix) do
    def primary?
      url_prefix.nil?
    end

    # site.data key suffix: the prefix lowercased with "-" turned into "_"
    # so it stays valid Liquid dot-notation (site.data.authors_nb_no, not
    # site.data["authors_nb-NO"]). nil for the primary locale, same as
    # url_prefix -- always derived, never stored, so it can't desync from it.
    def data_suffix
      url_prefix&.downcase&.tr("-", "_")
    end
  end

  # Yields one Locale per entry in a contentful_locales config value
  # (site.config["contentful_locales"]), first = primary. When `configured`
  # is nil (contentful_locales isn't set at all), yields a single
  # Locale.new(nil, nil) -- every query, URL, and site.data key this
  # produces is byte-identical to a build with no locale support at all,
  # which is the whole point: single-locale sites (the common case, and
  # every site this template has been tested against so far) never
  # exercise any of this machinery. A *configured* single-entry list (e.g.
  # contentful_locales: [nb-NO]) does NOT collapse to that same nil-code
  # path -- it still sends an explicit locale: nb-NO on every query, so a
  # deliberately named locale is never silently swapped for whatever the
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
  def self.each_locale(configured)
    if configured.nil?
      yield Locale.new(nil, nil)
      return
    end

    configured.each_with_index do |entry, index|
      code, prefix = locale_code_and_prefix(entry)
      yield index.zero? ? Locale.new(code, nil) : Locale.new(code, prefix)
    end
  end

  def self.locale_code_and_prefix(entry)
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

  # A collection's `dir` is usually one string, used for every locale --
  # but the URL path segment itself (unlike the locale-code prefix
  # each_locale already adds) often needs to be a different word per
  # locale (e.g. "produkter" vs "products"). Set `dir` to a Hash keyed
  # by locale code for that; anything else (a plain string, including
  # "") is used as-is regardless of locale, exactly as before this was
  # possible.
  def self.dir_for(collection, locale)
    dir = collection["dir"]
    return dir unless dir.is_a?(Hash)

    return dir[locale.code] if dir.key?(locale.code)

    raise "contentful_collections: dir is a per-locale Hash (#{dir.inspect}) but has no entry for " \
          "#{locale.code.inspect} (content_type: #{collection["content_type"]})" \
          "#{" -- is contentful_locales configured?" if locale.code.nil?}"
  end
end
