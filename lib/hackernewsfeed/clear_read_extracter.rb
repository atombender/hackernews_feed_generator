module Hackernewsfeed

  class ClearReadExtracter

    def initialize(directory)
      @directory = directory
      FileUtils.mkdir_p(@directory)
    end

    def get(url)
      file_name = File.join(@directory, Digest::SHA1.hexdigest(url))
      if File.exist?(file_name)
        logger.info "[cached] #{url}"
        File.read(file_name)
      else
        logger.info "[clean] #{url}"
        begin
          client = HTTPClient.new(nil, USER_AGENT)
          client.connect_timeout = 10
          client.send_timeout = 30
          client.receive_timeout = 30
          response = client.get("http://api.thequeue.org/v1/clear?url=#{url}&format=json")
        rescue SignalException
          raise
        rescue Exception => e
          logger.info "Error cleaning URL <#{url}>: #{e.class}: #{e}"
          response = nil
        end
        if response and response.status == 200
          result = JSON.parse(response.body)
          if result['status'] == 'success'
            logger.info "[clean OK] #{url}"
            content = result['item']['description']
            content.gsub!("&lt;", '<')
            content.gsub!("&gt;", '>')
            content.gsub!("&quot;", '"')
            content.gsub!("&amp;", '&')

            temp_file_name = "#{file_name}.new"
            File.open(temp_file_name, "w") { |f| f << content }
            FileUtils.mv(temp_file_name, file_name)
            return content
          else
            logger.info "[clean fail] #{url}"
            return '[Clear Read API was not able to process the page]'
          end
        else
          logger.info "[clean error] #{url}"
          return '[Error processing with Clear Read API]'
        end
      end
    end

    private

      def logger; Hackernewsfeed.logger; end

  end

end