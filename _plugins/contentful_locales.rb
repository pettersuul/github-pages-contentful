module ContentfulJekyll
  # code: locale to query, nil = no `locale` param (space's default).
  # url_prefix: nil for the primary locale, else its URL prefix. code and
  # url_prefix are both nil in different cases (no locales configured vs.
  # the primary locale), so call sites must check #primary?, not either
  # field directly.
  Locale = Struct.new(:code, :url_prefix) do
    def primary?
      url_prefix.nil?
    end

    # site.data key suffix: url_prefix lowercased, "-" -> "_" for valid
    # Liquid dot-notation. Derived, never stored, so it can't desync from
    # url_prefix.
    def data_suffix
      url_prefix&.downcase&.tr("-", "_")
    end
  end

  # Yields one Locale per contentful_locales entry, first = primary. A
  # nil/empty config yields a single Locale.new(nil, nil), identical to a
  # build with no locale support (the `.empty?` check matters: an explicit
  # `[]` would otherwise silently iterate zero entries and fetch nothing).
  # A configured single-entry list still sends an explicit `locale:` on
  # every query, unlike the unconfigured case, so it never silently falls
  # back to the space's default locale instead.
  #
  # An entry is a plain locale code (prefix == code) or a {code:, prefix:}
  # Hash for a different URL/site.data prefix -- explicit rather than
  # auto-derived from the code's region subtag, since that has a real
  # collision case (en-US and en-GB can't both shorten to "en").
  def self.each_locale(configured)
    if configured.nil? || configured.empty?
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

    # YAML parses bare no/yes/on/off as booleans -- catches the
    # `prefix: no` (Norwegian) trap before it silently falls back to `code`.
    if [true, false].include?(prefix)
      raise "contentful_locales: prefix for #{code} parsed as the boolean #{prefix.inspect}, not a string -- " \
            "quote it in _config.yml (e.g. prefix: \"no\")"
    end

    [code, prefix]
  end

  # `dir` is usually one string used for every locale; set it to a Hash
  # keyed by locale code when the path segment itself needs translating
  # (e.g. "produkter" vs "products"), not just prefixing.
  def self.dir_for(collection, locale)
    dir = collection["dir"]
    return dir unless dir.is_a?(Hash)

    return dir[locale.code] if dir.key?(locale.code)

    raise "contentful_collections: dir is a per-locale Hash (#{dir.inspect}) but has no entry for " \
          "#{locale.code.inspect} (content_type: #{collection["content_type"]})" \
          "#{" -- is contentful_locales configured?" if locale.code.nil?}"
  end
end
