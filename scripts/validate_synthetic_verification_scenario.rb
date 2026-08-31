#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

unless ARGV.length == 1
  warn "usage: #{File.basename($PROGRAM_NAME)} <scenario.json>"
  exit 2
end

scenario_path = ARGV.fetch(0)
unless File.file?(scenario_path)
  warn "synthetic scenario validation failed: scenario fixture is missing"
  exit 2
end

begin
  scenario_data = File.binread(scenario_path)
  scenario = JSON.parse(scenario_data)
rescue JSON::ParserError, SystemCallError
  warn "synthetic scenario validation failed: scenario fixture is unreadable JSON"
  exit 1
end

problems = []
provenance = scenario.fetch("provenance", {})
candidate = scenario.fetch("candidateProfile", {})
opportunity = scenario.fetch("opportunityContext", {})
sessions = scenario.fetch("sessions", [])

problems << "synthetic must be true" unless scenario["synthetic"] == true
problems << "runID must be a safe non-empty identifier" unless scenario.fetch("runID", "").match?(/\A[A-Za-z0-9._-]{1,80}\z/)
problems << "provenance schemaVersion must be 1" unless provenance["schemaVersion"] == 1
unless provenance["origin"] == "project_authored_synthetic_fixture"
  problems << "provenance origin is not the reviewed project fixture class"
end
unless provenance["containsRealPersonalData"] == false
  problems << "provenance must declare containsRealPersonalData=false"
end
unless provenance["reviewedForRelease"] == true
  problems << "provenance must declare reviewedForRelease=true"
end
problems << "answerProvider must be local_qwen" unless scenario["answerProvider"] == "local_qwen"
unless ["local_parakeet", "apple_speech"].include?(scenario["asrProvider"])
  problems << "asrProvider must be an approved local provider"
end
problems << "qwenModel must be non-empty" unless scenario.fetch("qwenModel", "").is_a?(String) && !scenario.fetch("qwenModel", "").strip.empty?
problems << "diagnosticTraceMode must be metadataOnly" unless scenario["diagnosticTraceMode"] == "metadataOnly"
unless candidate.fetch("id", "").start_with?("synthetic-") && candidate["displayName"] == "Synthetic Candidate"
  problems << "candidate identity must use the reviewed synthetic identity contract"
end
unless opportunity.fetch("id", "").start_with?("synthetic-")
  problems << "opportunity identity must use the reviewed synthetic identity contract"
end
unless candidate["evidence"].is_a?(Array) && !candidate["evidence"].empty?
  problems << "candidate evidence must be non-empty"
end
unless opportunity["evidence"].is_a?(Array) && !opportunity["evidence"].empty?
  problems << "opportunity evidence must be non-empty"
end
unless sessions.is_a?(Array) && !sessions.empty?
  problems << "sessions must be non-empty"
end

turns = []
visible_needles = []
if sessions.is_a?(Array)
  session_ids = sessions.each_with_object([]) do |session, identifiers|
    identifiers << session["id"] if session.is_a?(Hash)
  end
  problems << "session identifiers must be unique" unless session_ids.uniq.length == session_ids.length
  sessions.each_with_index do |session, session_index|
    unless session.is_a?(Hash) && session.fetch("id", "").match?(/\A[A-Za-z0-9._-]{1,80}\z/)
      problems << "session #{session_index + 1} must have a safe identifier"
      next
    end
    session_turns = session["turns"]
    unless session_turns.is_a?(Array) && !session_turns.empty?
      problems << "session #{session_index + 1} turns must be non-empty"
      next
    end
    session_turns.each_with_index do |turn, turn_index|
      label = "session #{session_index + 1} turn #{turn_index + 1}"
      unless turn.is_a?(Hash)
        problems << "#{label} must be an object"
        next
      end
      text = turn["text"]
      expected_trigger = turn["expectedShouldTrigger"]
      rate = turn["rate"]
      voice_slot = turn["voiceSlot"]
      rapid = turn.fetch("rapid", false)
      needle = turn.fetch("expectedQuestionNeedle", "")
      problems << "#{label} text must be non-empty" unless text.is_a?(String) && !text.strip.empty? && text.length <= 2_000
      problems << "#{label} expectedShouldTrigger must be boolean" unless [true, false].include?(expected_trigger)
      problems << "#{label} rate must be an integer from 80 through 300" unless rate.is_a?(Integer) && rate.between?(80, 300)
      problems << "#{label} voiceSlot must be an integer from 0 through 2" unless voice_slot.is_a?(Integer) && voice_slot.between?(0, 2)
      problems << "#{label} rapid must be boolean" unless [true, false].include?(rapid)
      if expected_trigger == true
        normalized_text = text.is_a?(String) ? text.downcase.gsub(/[^[:alnum:]]+/, " ").strip : ""
        normalized_needle = needle.is_a?(String) ? needle.downcase.gsub(/[^[:alnum:]]+/, " ").strip : ""
        needle_words = normalized_needle.scan(/[[:alnum:]]+/)
        unless normalized_needle.length.between?(8, 200) &&
               needle_words.length >= 2 &&
               needle_words.any? { |word| word.length >= 5 } &&
               normalized_text.include?(normalized_needle)
          problems << "#{label} triggering utterance requires a specific multi-word needle copied from its text"
        end
        visible_needles << normalized_needle unless rapid == true || normalized_needle.empty?
      elsif needle.is_a?(String) && !needle.strip.empty?
        problems << "#{label} non-triggering utterance must not declare an expectedQuestionNeedle"
      end
      if rapid == true
        problems << "#{label} rapid utterance must itself trigger generation" unless expected_trigger == true
        following = session_turns[turn_index + 1]
        unless following.is_a?(Hash) && following["expectedShouldTrigger"] == true
          problems << "#{label} rapid utterance must be followed by a triggering turn"
        end
      end
      turns << turn
    end
  end
end
unless visible_needles.uniq.length == visible_needles.length
  problems << "visible triggering utterances must use unique expectedQuestionNeedle values"
end

session_count = sessions.is_a?(Array) ? sessions.length : 0
turn_count = turns.length
trigger_count = turns.count { |turn| turn["expectedShouldTrigger"] == true }
reject_count = turns.count { |turn| turn["expectedShouldTrigger"] == false }
rapid_count = turns.count { |turn| turn.fetch("rapid", false) == true }
visible_count_minimum = trigger_count - rapid_count
visible_count_maximum = trigger_count

expected_counts = {
  "expectedSessionCount" => session_count,
  "expectedTurnCount" => turn_count,
  "expectedTriggerCount" => trigger_count,
  "expectedRejectCount" => reject_count,
  "expectedVisibleCountMinimum" => visible_count_minimum,
  "expectedVisibleCountMaximum" => visible_count_maximum,
  "expectedRapidTransitionCount" => rapid_count
}
expected_counts.each do |key, actual|
  value = scenario[key]
  problems << "#{key} must be the exact non-negative integer #{actual}" unless value.is_a?(Integer) && value >= 0 && value == actual
end
problems << "expectedVisibleCount is timing-dependent; declare exact minimum and maximum counts" if scenario.key?("expectedVisibleCount")
problems << "expectedRapidCancellationCount is timing-dependent; declare expectedRapidTransitionCount" if scenario.key?("expectedRapidCancellationCount")

strings = []
keys = []
walk = lambda do |value|
  case value
  when Hash
    value.each do |key, child|
      keys << key.to_s
      walk.call(child)
    end
  when Array
    value.each { |child| walk.call(child) }
  when String
    strings << value
  end
end
walk.call(scenario)

if keys.any? { |key| key.match?(/\A(?:api[_-]?key|password|private[_-]?key|secret|credential|access[_-]?token)\z/i) }
  problems << "scenario contains a credential-shaped field"
end

joined = strings.join("\n")
if joined.match?(%r{/(?:Users|home)/[^/\s]+})
  problems << "scenario contains an absolute user-home path"
end
if joined.match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/) ||
   joined.match?(/\b(?:sk|ghp|xox[baprs])-[A-Za-z0-9_-]{20,}\b/)
  problems << "scenario contains a credential-shaped value"
end

reserved_domains = ["example.com", "example.org", "example.net", "invalid"]
emails = joined.scan(/\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b/i).flatten
unless emails.all? { |domain| reserved_domains.any? { |reserved| domain.downcase == reserved || domain.downcase.end_with?(".#{reserved}") } }
  problems << "scenario contains a non-reserved email address"
end

unless problems.empty?
  problems.uniq.each { |problem| warn "synthetic scenario validation failed: #{problem}" }
  exit 1
end

puts "SYNTHETIC_SCENARIO_VALIDATION=passed"
puts "SYNTHETIC_SCENARIO_SHA256=#{Digest::SHA256.hexdigest(scenario_data)}"
puts "SYNTHETIC_SCENARIO_SESSIONS=#{session_count}"
puts "SYNTHETIC_SCENARIO_TURNS=#{turn_count}"
puts "SYNTHETIC_SCENARIO_TRIGGERS=#{trigger_count}"
puts "SYNTHETIC_SCENARIO_REJECTS=#{reject_count}"
puts "SYNTHETIC_SCENARIO_VISIBLE_MINIMUM=#{visible_count_minimum}"
puts "SYNTHETIC_SCENARIO_VISIBLE_MAXIMUM=#{visible_count_maximum}"
puts "SYNTHETIC_SCENARIO_RAPID_TRANSITIONS=#{rapid_count}"
