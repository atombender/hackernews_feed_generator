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

APP_VERSION = "0.1".freeze

USER_AGENT = "hackernews_feed_generator/#{APP_VERSION} (https://github.com/alexstaubo/hackernews_feed_generator)".freeze

class FeedParser
  def initialize(url)
    @url =url
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

  def get(url, &block)
    content = nil
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
    return content
  end
end

class PageCleaner
  def initialize
  end

  def process(url, content)
    begin
      base_uri = URI.parse(url)
      base_uri.path = '/'
      path = URI.parse(url).path
    rescue URI::InvalidURIError
      base_uri = url
      path = '/'
    end

    document = Nokogiri::HTML(content)
    begin
      return Readability::Document.new(document, base_uri, path).content
    rescue Exception => e
      $stderr.puts "Exception processing document: #{e.class}: #{e}"
      nil
    end
  end
end

class Feed
  def initialize(path, page_cache)
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
  end

  def save
    File.open(@path, 'w') { |f| f << YAML.dump(@items) }
  end

  def garbage_collect
    @items.delete_if { |item| Time.parse(item[:updated_at]) < Time.now - 86400 }
  end

  def add_items_from_document(document)
    document.xpath('/rss/channel/item').each do |item_element|
      item_url = item_element.xpath('link').text
      comments_url = item_element.xpath('comments').text

      id = $1 if comments_url =~ /id=(\d+)/
      id ||= comments_url
      id = "hackernews:#{id}"

      item = @items.select { |item| item[:id] == id }[0]
      unless item
        item = {}
        @items << item
      end
      
      item[:title] = item_element.xpath('title').text

      uri = URI.parse(item_url) rescue nil
      if uri
        domain = uri.host
        domain = $1 if domain =~ /(?:^|\.)([^.]+\.[^.]+)$/
        item[:title] << " [#{domain}]" if domain
      end

      item[:comments_url] = comments_url
      item[:url] = item_url
      item[:id] = id
      item[:updated_at] = Time.now.xmlschema  # TODO: Read from page

      content = @page_cache.get(item_url)
      content &&= PageCleaner.new.process(item_url, content)
      item[:content] = content
    end
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
      xml.link :rel => :self, :href => @url
      xml.link :rel => :alternate, :href => 'http://news.ycombinator.com/'
      feed.items.each do |item|
        xml.entry do
          xml.title item[:title]
          xml.link :rel => :alternate, :href => item[:url], :type => "text/html"
          xml.id item[:id]
          xml.updated item[:updated_at]
          xml.content :type => :html do
            body = '<div>'
            if item[:content]
              body << item[:content]
            else
              body << "<p><em>[Failed to fetch page]</em></p>"
            end
            body << "<hr/><p><a href=\"#{item[:comments_url]}\">[Hacker News discussion]</a></p></div>"
            xml.text! body
          end
        end
      end
    end
  end
end

class Controller
  def initialize
    @output_path = '-'
  end

  def run!(argv)
    argv.options do |opts|
      opts.banner = "Usage: #{File.basename($0)} [OPTIONS] FEED-URL"
      opts.separator ""
      opts.on("-v", "--verbose") do
        verbose = true
      end
      opts.on("-o FILE", "--output FILE", "Write feed to this file.") do |file_name|
        @output_path = file_name
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
    if argv.empty?
      abort "No URLs specified."
    end
    @cache_path ||= File.join(ENV['TMP'] || '/tmp', 'hnfeed.cache')
    @page_cache = PageCache.new(@cache_path)
    argv.each do |url|
      parser = FeedParser.new(url)

      feed = Feed.new(File.join(@cache_path, 'item_cache.yml'), @page_cache)
      feed.add_items_from_document(parser.parse)
      feed.save

      Tempfile.open("feed") do |tempfile|
        generator = FeedGenerator.new(url, tempfile, @page_cache)
        generator.generate(feed)
        if @output_path == '-'
          tempfile.seek(0)
          $stdout << tempfile.read
        else
          tempfile.close
          original_mask = File.stat(@output_path).mode rescue nil
          FileUtils.rm_f(@output_path)
          FileUtils.mv(tempfile.path, @output_path)
          FileUtils.chmod(original_mask, @output_path) if original_mask rescue nil
        end
      end
    end
  end
end

$stdout.sync = $stderr.sync = true

Thread.abort_on_exception = false

Controller.new.run!(ARGV)
