#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

unless ARGV.length == 2
  warn "usage: #{File.basename($PROGRAM_NAME)} <audio.wav> <provenance.json>"
  exit 2
end

audio_path, provenance_path = ARGV
abort("audio fixture is missing: #{audio_path}") unless File.file?(audio_path)
abort("audio provenance is missing: #{provenance_path}") unless File.file?(provenance_path)

manifest = JSON.parse(File.read(provenance_path))
problems = []
problems << "schema_version must be 1" unless manifest["schema_version"] == 1
problems << "synthetic must be true" unless manifest["synthetic"] == true
problems << "contains_real_personal_data must be false" unless manifest["contains_real_personal_data"] == false
problems << "generator must be macos_say" unless manifest["generator"] == "macos_say"

audio = manifest.fetch("audio", {})
actual_sha256 = Digest::SHA256.file(audio_path).hexdigest
actual_size = File.size(audio_path)
problems << "audio filename does not match" unless audio["filename"] == File.basename(audio_path)
problems << "audio SHA-256 does not match" unless audio["sha256"] == actual_sha256
problems << "audio size does not match" unless audio["size_bytes"] == actual_size

utterances = manifest.fetch("utterances", [])
problems << "exactly three synthetic utterances are required" unless utterances.length == 3
utterance_ids = utterances.map { |utterance| utterance["id"] }.compact
problems << "utterance IDs must be unique and non-empty" unless utterance_ids.length == 3 && utterance_ids.uniq.length == 3
utterances.each_with_index do |utterance, index|
  text = utterance.fetch("text", "").strip
  terms = utterance.fetch("expected_transcript_terms", [])
  problems << "utterance #{index + 1} text is empty" if text.empty?
  unless terms.is_a?(Array) && terms.length >= 2 && terms.all? { |term| term.is_a?(String) && !term.strip.empty? }
    problems << "utterance #{index + 1} requires at least two expected transcript terms"
  end
end

serialized = JSON.generate(manifest)
forbidden_markers = [
  "/Users/", "/home/", "-----BEGIN PRIVATE KEY-----", "API key", "password"
]
forbidden_markers.each do |marker|
  problems << "provenance contains forbidden marker: #{marker}" if serialized.downcase.include?(marker.downcase)
end
problems << "provenance contains an email address" if serialized.match?(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)

unless problems.empty?
  problems.each { |problem| warn "synthetic audio provenance failure: #{problem}" }
  exit 1
end

puts "SYNTHETIC_AUDIO_PROVENANCE=passed"
puts "SYNTHETIC_AUDIO_SHA256=#{actual_sha256}"
puts "SYNTHETIC_AUDIO_UTTERANCES=#{utterances.length}"
