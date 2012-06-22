module Hackernewsfeed

  class FeedGenerator
    
    def initialize(url, output, page_cache)
      @url = url
      @output = output
      @page_cache = page_cache
    end

    def generate(feed)
      urls = feed.items.map { |item| item[:url] }.uniq
      
      threads = urls.map { |url|
        Thread.start {
          @page_cache.get(url)
        }
      }
      begin
        Timeout.timeout(60 * 2) do
          while threads.any?
            threads.delete_if { |t| !t.alive? }
            sleep(0.1)
          end
        end
      rescue Timeout::Error
        logger.error "Timeout waiting for all items to be fetched."
      end

      xml = Builder::XmlMarkup.new(:target => @output)
      xml.instruct!
      xml.feed :xmlns => 'http://www.w3.org/2005/Atom' do  
        xml.title 'Hacker News'
        xml.id @url
        xml.link :rel => :self, :type => 'application/atom+xml', :href => @url
        xml.link :rel => :alternate, :type => 'text/html', :href => 'http://news.ycombinator.com/'
        if feed.items.any?
          xml.updated feed.items.map { |item| item[:updated_at] }.max
        else
          xml.updated Time.now.xmlschema
        end
        feed.items.each do |item|
          xml.entry do
            title = "#{item[:title]}"
            uri = URI.parse(item[:url]) rescue nil
            if uri
              domain = uri.host
              domain = $1 if domain =~ /(?:^|\.)([^.]+\.[^.]+)$/
              title = [title, "[#{domain}]"].join(' ') if domain and title !~ /\[#{Regexp.escape(domain)}/
            else
              domain = nil
            end

            xml.title title
            xml.link :rel => :alternate, :href => item[:url], :type => "text/html"

            id = $1 if item[:comments_url] =~ /id=(\d+)/
            id ||= item[:comments_url]
            xml.id "tag:purefiction.net,2011:hackernews-#{id}"
            xml.author do
              xml.name "Hacker News"
            end
            xml.updated item[:updated_at]
            xml.content :type => :html do
              body = '<div>'
              if item[:content]
                body << item[:content]
              else
                body << "<p><em>[Failed to fetch page]</em></p>"
              end
              body << "<hr/><p><a href=\"#{item[:comments_url]}\">[Hacker News discussion]</a></p></div>"
              xml.cdata! body
            end
          end
        end
      end
    end

    private

      def logger; Hackernewsfeed.logger; end

  end

end