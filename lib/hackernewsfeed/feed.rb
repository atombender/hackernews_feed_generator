module Hackernewsfeed

  class Feed
    def initialize(path, page_cache, processor)
      @processor = processor
      @path = path
      @page_cache = page_cache
      @items = []
      load
    end

    def load
      @items = []
      if File.exist?(@path)
        @items.concat(Psych.load(File.read(@path)))
        garbage_collect
      end
      @changed = false
    end

    def save
      File.atomic_write(@path) { |f| f << Psych.dump(@items) }
    end

    def garbage_collect
      @items.delete_if { |item| Time.parse(item[:updated_at]) < Time.now - 86400 }
    end

    def normalize_url(url)
      uri = URI.parse(url)
      uri.fragment = nil
      uri.to_s
    end

    def add_items_from_document(document)
      document.xpath('/rss/channel/item').each do |item_element|
        item_url = normalize_url(item_element.xpath('link').text)
        comments_url = item_element.xpath('comments').text
        item = @items.select { |item| item[:comments_url] == comments_url }[0]
        unless item
          item = {}
          item[:title] = item_element.xpath('title').text
          item[:comments_url] = comments_url
          item[:url] = item_url
          item[:updated_at] ||= Time.now.xmlschema  # TODO: Read from page
          item[:content] = @processor.get(item_url)
          @items << item

          @changed = true
        end
      end
    end

    def changed?
      @changed
    end

    attr_reader :items
  end

end