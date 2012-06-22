module Hackernewsfeed

  class Tool

    def initialize
      @output_path = '-'
      @extracter_type = 'readability'
      @cache_path = '/tmp/hackernewsfeed'
    end

    def run!(argv)
      $stdout.sync = $stderr.sync = true

      Thread.abort_on_exception = false

      argv.options do |opts|
        opts.banner = "Usage: #{File.basename($0)} [OPTIONS] FEED-URL SELF-URL"
        opts.separator ""
        opts.on("-v", "--verbose") do
          verbose = true
        end
        opts.on("-o FILE", "--output FILE", "Write feed to this file.") do |file_name|
          @output_path = file_name
        end
        opts.on("-p PROCESSOR", "--processor PROCESSOR", "Specify either 'readability' (default) or 'clear_read' (Clear Read API).") do |processor|
          @extracter_type = processor
        end
        opts.on("--cache-directory DIR", "Store fetched pages and items in DIR.") do |path|
          @cache_path = path
        end
        opts.on("-h", "--help", "Show this help message.") do
          puts opts
          exit
        end
        opts.order!
      end

      @page_cache = PageCache.new(@cache_path)

      case @extracter_type
        when 'clear_read'
          @extracter = ClearReadExtracter.new(@cache_path)
        else
          @extracter = ReadabilityExtracter.new(@page_cache)
      end
      
      source_url = argv.shift
      self_url = argv.shift
      unless source_url and self_url
        abort "No URLs specified."
      end
      
      @cache_path ||= File.join(ENV['TMP'] || '/tmp', 'hnfeed.cache')
      
      logger.info "Importing items"
      feed = Feed.new(File.join(@cache_path, 'item_cache.yml'), @page_cache, @extracter)
      feed.add_items_from_document(FeedParser.new(source_url).parse)
      feed.save

      if feed.changed? or not File.exist?(@output_path)
        logger.info "Writing #{@output_path}"
        File.atomic_write(@output_path) do |file|
          generator = FeedGenerator.new(self_url, file, @page_cache)
          generator.generate(feed)
        end
      else
        logger.info "Feed has not changed, not writing anything"
      end
    end

    private

      def logger; Hackernewsfeed.logger; end

  end

end
