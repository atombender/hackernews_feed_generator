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

require 'tempfile'
require 'base64'
require 'httpclient'
require 'optparse'
require 'nokogiri'
require 'builder'
require 'time'
require 'fileutils'
require 'readability'

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
    file_name = File.join(@directory,
      Base64.encode64(url).gsub(/[=?\/\n]/, '').strip)
    if File.exist?(file_name)
      $stderr.puts "[cached] #{url}"
      content = File.read(file_name)
    else
      $stderr.puts " [fetch] #{url}"
      response = HTTPClient.new.get(url)
      if response.status == 200
        content = response.body
        temp_file_name = "#{file_name}.new"
        File.open(temp_file_name, "w") { |f| f << content }
        FileUtils.mv(temp_file_name, file_name)
      end
    end
    return content
  end
end

class PageCleaner
  def initialize
  end

  def process(url, content)
    base_uri = URI.parse(url)
    base_uri.path = '/'

    path = URI.parse(url).path

    document = Nokogiri::HTML(content)
    return Readability::Document.new(document, base_uri, path).content
  end
end

class FeedGenerator
  def initialize(url, output, page_cache)
    @url = url
    @output = output
    @page_cache = page_cache
  end

  def generate(feed_document)
    urls = feed_document.xpath('/rss/channel/item/link').map { |node| node.text }
    threads = urls.map { |url|
      Thread.start { @page_cache.get(url) }
    }
    while threads.any?
      threads.delete_if { |t| !t.alive? }
      sleep(0.1)
    end

    xml = Builder::XmlMarkup.new(:target => @output)
    xml.instruct!
    xml.feed :xmlns => 'http://www.w3.org/2005/Atom' do  
      xml.title 'Hacker News'
      xml.link :rel => :self, :href => @url
      xml.link :rel => :alternate, :href => 'http://news.ycombinator.com/'

      feed_document.xpath('/rss/channel/item').each do |item_element|
        xml.entry do
          comments_url = item_element.xpath('comments')
          item_url = item_element.xpath('link').text

          guid = "hackernews:"
          guid << $1 if comments_url =~ /id=(\d+)/

          title = item_element.xpath('title').text
          title << " [#{URI.parse(item_url).host}]" rescue ''

          content = @page_cache.get(item_url)
          content &&= PageCleaner.new.process(item_url, content)

          xml.title title
          xml.link :rel => :alternate, :href => item_url, :type => "text/html"
          xml.id guid
          xml.updated Time.now.xmlschema  # TODO
          xml.content :type => :html do
            body = ''
            if content
              body << content
            else
              body << "<p><em>[Failed to fetch page]</em></p>"
            end
            body << "<hr/><p><a href='#{comments_url}'>[Hacker News discussion]</a></p>"
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
      opts.on("--cache-directory DIR", "Store fetched pages in DIR.") do |path|
        @page_cache = PageCache.new(path)
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
    @page_cache ||= PageCache.new("#{ENV['TMP'] || '/tmp'}/hnfeed.cache")
    argv.each do |url|
      document = FeedParser.new(url).parse
      Tempfile.open("feed") do |tempfile|
        generator = FeedGenerator.new(url, tempfile, @page_cache)
        generator.generate(document)
        if @output_path == '-'
          tempfile.seek(0)
          $stdout << tempfile.read
        else
          tempfile.close
          FileUtils.rm_f(@output_path)
          FileUtils.mv(tempfile.path, @output_path)
        end
      end
    end
  end
end

$stdout.sync = $stderr.sync = true

Controller.new.run!(ARGV)
