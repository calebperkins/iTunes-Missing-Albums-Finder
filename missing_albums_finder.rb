#!/usr/bin/env ruby -wKU

require "set"
require "json"
require "net/http"
require 'thread'

require 'fuzzy_match'
require "itunes/library"

module MissingAlbumsFinder
  class ArtistNotFound < Exception
  end

  class Worker < Thread
    def initialize(queue)
      super do
        Net::HTTP.start("itunes.apple.com", 80) do |http|
          until (work = queue.pop).nil? do
            do_work(http, work[0], work[1])
          end
        end
      end
    end

    private

    def do_work(http, artist, albums)
      all_albums = get_all_albums(http, artist)
      # Use fuzzy matching because album names might not match up exactly
      matcher = FuzzyMatch.new(all_albums)
      missing = all_albums - albums.map { |a| matcher.find(a) }
      if missing.size > 0
        puts "#{artist}: #{missing.to_a.join(', ')}"
      end
    rescue ArtistNotFound
      $stderr.puts "#{artist} was not found in iTunes database"
    end

    def get_latest_album(http, artist)
      artist_id = get_artist_id(http, artist)
      response = http.get("/lookup?id=#{artist_id}&entity=album")
      latest = JSON.parse(response.body)["results"]
      latest.select! { |r| r["wrapperType"] == "collection" }
      raise ArtistNotFound if latest.empty?
      latest.max { |a, b| a["releaseDate"] <=> b["releaseDate"] }["collectionName"]
    end

    def get_artist_id(http, artist)
      artist = URI.escape(artist)
      response = http.get("/search?entity=musicArtist&attribute=allArtistTerm&term=#{artist}&limit=5")
      results = JSON.parse(response.body)["results"]
      raise ArtistNotFound if results.empty?
      results.first["artistId"]
    end

    def get_all_albums(http, artist)
      artist_id = get_artist_id(http, artist)

      response = http.get("/lookup?id=#{artist_id}&entity=album")

      all_albums = JSON.parse(response.body)["results"]
      all_albums.select! { |r| r["wrapperType"] == "collection" }
      all_albums.collect! { |r| r["collectionName"].split("(").first.strip }
      all_albums.to_set
    end
  end # Worker

  class MissingAlbumsFinder
    def initialize(music_library_xml_path)
      library = ITunes::Library.load(File.expand_path(music_library_xml_path))

      @music = Hash.new { |hash, key| hash[key] = Set.new }.tap do |hash|
        library.music.tracks.each do |t|
          hash[t.artist] << t.album
        end
      end
    end

    def run(workers = 8)
      queue = Queue.new
      @music.entries.each { |w| queue << w }
      workers.times { queue << nil } # stopping marker
      workers.times.map { Worker.new(queue) }.each(&:join)
    end
  end # MissingAlbumsFinder
end # Module

if __FILE__ == $PROGRAM_NAME
  xml = ARGV.empty? ? "~/Music/iTunes/iTunes\ Music\ Library.xml" : ARGV.first
  MissingAlbumsFinder::MissingAlbumsFinder.new(xml).run
end
