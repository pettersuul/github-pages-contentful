begin
  require "dotenv/load"
rescue LoadError
  nil
end

require "contentful"

module ContentfulClient
  def self.preview?
    ENV["CONTENTFUL_PREVIEW"] == "true"
  end

  def self.build
    space = ENV["CONTENTFUL_SPACE_ID"]
    is_preview = preview?
    token = is_preview ? ENV["CONTENTFUL_PREVIEW_ACCESS_TOKEN"] : ENV["CONTENTFUL_ACCESS_TOKEN"]
    environment = ENV["CONTENTFUL_ENVIRONMENT"] || "master"

    return nil if space.nil? || token.nil?

    Contentful::Client.new(
      space: space,
      access_token: token,
      environment: environment,
      api_url: is_preview ? "preview.contentful.com" : "cdn.contentful.com"
    )
  end
end
