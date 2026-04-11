#!/usr/bin/env ruby
require 'rss'
require 'net/http'
require 'json'
require 'fileutils'

FEED_URL = 'https://henryaj.substack.com/feed'
OUTPUT   = File.join(__dir__, '..', '_data', 'substack.json')
LIMIT    = 5

uri  = URI(FEED_URL)
xml  = Net::HTTP.get(uri)
feed = RSS::Parser.parse(xml)

posts = feed.items.first(LIMIT).map do |item|
  {
    title: item.title,
    url:   item.link,
    date:  item.pubDate.strftime('%Y-%m-%d')
  }
end

FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate(posts))
puts "Wrote #{posts.length} posts to #{OUTPUT}"
