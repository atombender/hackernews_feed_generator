module Hackernewsfeed

  class FeedParser

    def initialize(url)
      @url = url
    end

    def parse
      if @url =~ %r{file://(.*)}
        feed_data = File.read($1)
      else
        response = HTTPClient.new.get(@url)
        unless response.status == 200
          raise "Failed to get feed: HTTP status #{response.status}"
        end
        feed_data = response.body
      end
      return Nokogiri::XML(feed_data)
    end

  end

end