module Hackernewsfeed

  class ReadabilityExtracter

    def initialize(cache)
      @cache = cache
    end

    def get(url)
      content = @cache.get(url)
      if content
        if content =~ /<html/i
          begin
            return Readability::Document.new(content,
              :remove_empty_nodes => true,
              :tags => %w(
                div p h1 h2 h3 h4 h5 h6 h7 img
                table ul ol li em i strong b pre code tt
              )).content
          rescue SignalException
            raise
          rescue Exception => e
            logger.info "Exception processing document: #{e.class}: #{e}"
            logger.info caller.join("\n")
            nil
          end
        else
          logger.info "Not HTML: #{url}"
          return '[Non-HTML content]'
        end
      end
    end

    private

      def logger; Hackernewsfeed.logger; end

  end

end