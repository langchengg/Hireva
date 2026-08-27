#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

unless ARGV.length == 2
  warn "usage: #{File.basename($PROGRAM_NAME)} <audio.wav> <provenance.json>"
  exit 2
end

audio_path, provenance_path = ARGV
unless File.file?(audio_path) && !File.symlink?(audio_path)
  warn "synthetic audio provenance failure: audio fixture must be a regular, non-symlink file"
  exit 1
end
unless File.file?(provenance_path) && !File.symlink?(provenance_path)
  warn "synthetic audio provenance failure: provenance must be a regular, non-symlink file"
  exit 1
end

begin
  manifest = JSON.parse(File.binread(provenance_path))
rescue JSON::ParserError, SystemCallError
  warn "synthetic audio provenance failure: provenance is not readable valid JSON"
  exit 1
end

unless manifest.is_a?(Hash)
  warn "synthetic audio provenance failure: provenance root must be an object"
  exit 1
end

problems = []
problems << "schema_version must be 1" unless manifest["schema_version"] == 1
problems << "synthetic must be true" unless manifest["synthetic"] == true
problems << "contains_real_personal_data must be false" unless manifest["contains_real_personal_data"] == false
problems << "generator must be macos_say" unless manifest["generator"] == "macos_say"

audio = manifest["audio"]
unless audio.is_a?(Hash)
  problems << "audio must be an object"
  audio = {}
end
begin
  actual_sha256 = Digest::SHA256.file(audio_path).hexdigest
  actual_size = File.size(audio_path)
rescue SystemCallError
  warn "synthetic audio provenance failure: audio fixture became unreadable"
  exit 1
end
problems << "audio filename does not match" unless audio["filename"] == File.basename(audio_path)
problems << "audio SHA-256 does not match" unless audio["sha256"] == actual_sha256
problems << "audio size does not match" unless audio["size_bytes"] == actual_size

utterances = manifest["utterances"]
unless utterances.is_a?(Array)
  problems << "utterances must be an array"
  utterances = []
end
problems << "exactly three synthetic utterances are required" unless utterances.length == 3
utterance_ids = utterances.map do |utterance|
  utterance.is_a?(Hash) ? utterance["id"] : nil
end
valid_ids = utterance_ids.all? do |identifier|
  identifier.is_a?(String) && identifier.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
end
problems << "utterance IDs must be unique, non-empty safe identifiers" unless valid_ids && utterance_ids.uniq.length == utterance_ids.length
all_normalized_terms = []
utterances.each_with_index do |utterance, index|
  unless utterance.is_a?(Hash)
    problems << "utterance #{index + 1} must be an object"
    next
  end

  raw_text = utterance["text"]
  text = raw_text.is_a?(String) ? raw_text.strip : ""
  terms = utterance["expected_transcript_terms"]
  problems << "utterance #{index + 1} text is empty" if text.empty?
  unless terms.is_a?(Array) && terms.length.between?(2, 8)
    problems << "utterance #{index + 1} requires between two and eight expected transcript terms"
    next
  end

  normalized_terms = terms.map do |term|
    term.is_a?(String) ? term.strip.downcase : ""
  end
  all_normalized_terms.concat(normalized_terms)
  unless normalized_terms.all? { |term| term.length.between?(3, 64) }
    problems << "utterance #{index + 1} transcript terms must each contain 3 to 64 characters"
  end
  if normalized_terms.uniq.length != normalized_terms.length
    problems << "utterance #{index + 1} transcript terms must be unique"
  end
  normalized_text = text.downcase
  normalized_terms.each do |term|
    next if term.empty?

    unless normalized_text.include?(term)
      problems << "utterance #{index + 1} transcript terms must occur in the utterance text"
      break
    end
  end
end
if all_normalized_terms.uniq.length != all_normalized_terms.length
  problems << "transcript terms must be globally unique across utterances"
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
