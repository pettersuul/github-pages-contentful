require_relative "contentful_client"

module ContentfulJekyll
  class PostsGenerator < Jekyll::Generator
    safe true
    priority :high

    def generate(site)
      client = ContentfulClient.build

      if client.nil?
        Jekyll.logger.warn "Contentful:", "CONTENTFUL_SPACE_ID / CONTENTFUL_ACCESS_TOKEN not set, skipping content fetch"
        return
      end

      content_type = site.config["contentful_content_type"] || "post"
      entries = client.entries(content_type: content_type, order: "-fields.publishDate")

      entries.each do |entry|
        site.pages << build_page(site, entry)
      end
    end

    private

    def build_page(site, entry)
      page = Jekyll::PageWithoutAFile.new(site, site.source, "posts/#{entry.fields[:slug]}", "index.html")
      page.content = entry.fields[:body].to_s
      page.data["layout"] = "post"
      page.data["title"] = entry.fields[:title]
      page.data["publish_date"] = entry.fields[:publish_date]
      page
    end
  end
end
