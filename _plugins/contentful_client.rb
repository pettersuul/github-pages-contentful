begin
  require "dotenv/load"
rescue LoadError
  nil
end

require "contentful"

module ContentfulClient
  def self.build
    space = ENV["CONTENTFUL_SPACE_ID"]
    token = ENV["CONTENTFUL_ACCESS_TOKEN"]
    environment = ENV["CONTENTFUL_ENVIRONMENT"] || "master"

    return nil if space.nil? || token.nil?

    Contentful::Client.new(
      space: space,
      access_token: token,
      environment: environment
    )
  end
end
