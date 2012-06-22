module Hackernewsfeed

  APP_VERSION = "0.2".freeze

  USER_AGENT = "hackernews_feed_generator/#{APP_VERSION} (+https://github.com/alexstaubo/hackernews_feed_generator)".freeze

  def self.logger
    @logger ||= Logger.new($stderr)
  end

end