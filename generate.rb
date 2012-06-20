#!/usr/bin/env ruby
# encoding: utf-8

ENV['BUNDLE_GEMFILE'] = File.expand_path('../Gemfile', __FILE__)

require 'rubygems'
begin
  require 'bundler'
rescue LoadError
  # Ignore this
else
  Bundler.setup
end

require 'timeout'
require 'tempfile'
require 'digest/sha1'
require 'httpclient'
require 'optparse'
require 'nokogiri'
require 'builder'
require 'time'
require 'fileutils'
require 'readability'
require 'active_support/core_ext/file/atomic'
require 'json'
require 'readability'

APP_VERSION = "0.2".freeze

USER_AGENT = "hackernews_feed_generator/#{APP_VERSION} (+https://github.com/alexstaubo/hackernews_feed_generator)".freeze

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
        abort "Failed to get feed: HTTP status #{response.status}"
      end
      feed_data = response.body
    end
    return Nokogiri::XML(feed_data)
  end
end

class PageCache
  def initialize(directory)
    @directory = directory
    FileUtils.mkdir_p(@directory)
  end

  def get(url)
    content = nil
    unless url =~ %r{http://news\.ycombinator\.com\/item\?}
      file_name = File.join(@directory, Digest::SHA1.hexdigest(url))
      if File.exist?(file_name)
        $stderr.puts "[cached] #{url}"
        content = File.read(file_name)
      else
        $stderr.puts " [fetch] #{url}"
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
          $stderr.puts "Error fetching URL <#{url}>: #{e.class}: #{e}"
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
end

class ClearReadClient
  def initialize(directory)
    @directory = directory
    FileUtils.mkdir_p(@directory)
  end

  def get(url)
    file_name = File.join(@directory, Digest::SHA1.hexdigest(url))
    if File.exist?(file_name)
      $stderr.puts "[cached] #{url}"
      File.read(file_name)
    else
      $stderr.puts "[clean] #{url}"
      begin
        client = HTTPClient.new(nil, USER_AGENT)
        client.connect_timeout = 10
        client.send_timeout = 30
        client.receive_timeout = 30
        response = client.get("http://api.thequeue.org/v1/clear?url=#{url}&format=json")
      rescue SignalException
        raise
      rescue Exception => e
        $stderr.puts "Error cleaning URL <#{url}>: #{e.class}: #{e}"
        response = nil
      end
      if response and response.status == 200
        result = JSON.parse(response.body)
        if result['status'] == 'success'
          $stderr.puts "[clean OK] #{url}"
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
          $stderr.puts "[clean fail] #{url}"
          return '[Clear Read API was not able to process the page]'
        end
      else
        $stderr.puts "[clean error] #{url}"
        return '[Error processing with Clear Read API]'
      end
    end
  end
end

class ReadabilityClient
  def initialize(cache)
    @cache = cache
  end

  def get(url)
    content = @cache.get(url)
    if content
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
        $stderr.puts "Exception processing document: #{e.class}: #{e}"
        $stderr.puts caller.join("\n")
        nil
      end
    end
  end
end

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
      @items.concat(YAML.load(File.open(@path)))
      garbage_collect
    end
    @changed = false
  end

  def save
    File.atomic_write(@path) { |f| f << YAML.dump(@items) }
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
      $stderr.puts "Timeout waiting for all items to be fetched."
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
end

class Controller
  def initialize
    @output_path = '-'
    @processor_type = 'readability'
  end

  def run!(argv)
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
        @processor_type = processor
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

    case @processor_type
      when 'clear_read'
        @processor = ClearReadClient.new(@cache_path + '/clear_read')
      else
        @processor = ReadabilityClient.new(@page_cache)
    end
    
    source_url = argv.shift
    self_url = argv.shift
    unless source_url and self_url
      abort "No URLs specified."
    end
    
    @cache_path ||= File.join(ENV['TMP'] || '/tmp', 'hnfeed.cache')
    
    feed = Feed.new(File.join(@cache_path, 'item_cache.yml'), @page_cache, @processor)
    feed.add_items_from_document(FeedParser.new(source_url).parse)
    feed.save

    if feed.changed? or not File.exist?(@output_path)
      File.atomic_write(@output_path) do |file|
        generator = FeedGenerator.new(self_url, file, @page_cache)
        generator.generate(feed)
      end
    end
  end
end

$stdout.sync = $stderr.sync = true

Thread.abort_on_exception = false

Controller.new.run!(ARGV)
