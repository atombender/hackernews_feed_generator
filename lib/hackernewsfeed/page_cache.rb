module Hackernewsfeed

  class PageCache

    EXPIRY_TIME = 14 * 60 * 60 * 24  # 14 days

    def initialize(directory)
      @directory = directory
      FileUtils.mkdir_p(@directory)
      Dir.glob(File.join(@directory, '*.cache')).each do |file_name|
        if File.file?(file_name) and File.stat(file_name).mtime < Time.now - EXPIRY_TIME
          logger.info "Purging old cache file #{file_name}"
          File.unlink(file_name)
        end
      end
    end

    def get(url)
      content = nil
      unless url =~ %r{http://news\.ycombinator\.com\/item\?}
        file_name = File.join(@directory, Digest::SHA1.hexdigest(url) + '.cache')
        if File.exist?(file_name)
          logger.info "[cached] #{url}"
          content = File.read(file_name)
        else
          logger.info "[fetch] #{url}"
          begin
            client = HTTPClient.new(nil, USER_AGENT)
            client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
            client.connect_timeout = 10
            client.send_timeout = 30
            client.receive_timeout = 30
            response = client.get(url)
          rescue SignalException
            raise
          rescue Exception => e
            logger.info "Error fetching URL <#{url}>: #{e.class}: #{e}"
            File.open(file_name, "w") { |f| f << '' }
          else
            if response.status == 200
              content = response.body
              temp_file_name = "#{file_name}.new"
              File.open(temp_file_name, "w") { |f| f << content }
              FileUtils.mv(temp_file_name, file_name)
            end
          end
        end
      end
      return content
    end

    private

      def logger; Hackernewsfeed.logger; end

  end
end
