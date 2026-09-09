require_relative "contentful_client"

module ContentfulJekyll
  class EntriesGenerator < Jekyll::Generator
    safe true
    priority :high

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
    end

    private

    def fetch_collection(site, client, collection)
      entries = client.entries(content_type: collection["content_type"], order: "-sys.updatedAt")

      entries.each do |entry|
        site.pages << build_page(site, entry, collection)
      end
    end

    def build_page(site, entry, collection)
      dir = [collection["dir"], entry.fields[:slug]].reject { |part| part.nil? || part.to_s.empty? }.join("/")

      page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")
      page.content = entry.fields[:body].to_s
      page.data["layout"] = collection["layout"]
      page.data["title"] = entry.fields[:title]
      page.data["publish_date"] = entry.fields[:publish_date]
      page
    end
  end
end
