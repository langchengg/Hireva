#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "set"

unless ARGV.length == 1
  warn "usage: #{File.basename($PROGRAM_NAME)} <fresh-output-directory>"
  exit 2
end

output_directory = File.expand_path(ARGV.fetch(0))
if File.exist?(output_directory) || File.symlink?(output_directory)
  warn "real-audio fixture output must be a fresh directory path"
  exit 2
end
output_parent = File.dirname(output_directory)
unless Dir.exist?(output_parent) && !File.symlink?(output_parent)
  warn "real-audio fixture output parent must be an existing non-symlink directory"
  exit 2
end

repository_root = File.expand_path("..", __dir__)
source_directory = File.join(
  repository_root,
  "Tests",
  "HirevaTests",
  "Fixtures",
  "InterviewCampaign"
)
source_files = {
  "candidateProfiles" => "candidate_profiles.json",
  "opportunityContexts" => "opportunity_contexts.json",
  "sessions" => "interview_sessions.json",
  "turns" => "dialogue_turns.json",
  "roleTaxonomy" => "role_taxonomy.json",
  "sourceProvenance" => "source_provenance.json"
}.freeze

source_data = source_files.to_h do |key, filename|
  file = File.join(source_directory, filename)
  abort("missing campaign source fixture: #{filename}") unless File.file?(file) && !File.symlink?(file)
  [key, {"filename" => filename, "data" => File.binread(file)}]
end
source_json = source_data.transform_values { |value| JSON.parse(value.fetch("data")) }
abort("campaign source fixtures must all be synthetic") unless source_json.values.all? { |value| value["synthetic"] == true }

roles = source_json.fetch("roleTaxonomy").fetch("coreRoleFamilies")
profiles = source_json.fetch("candidateProfiles").fetch("profiles").to_h { |profile| [profile.fetch("id"), profile] }
opportunities = source_json.fetch("opportunityContexts").fetch("opportunities").to_h do |opportunity|
  [opportunity.fetch("id"), opportunity]
end
sessions = source_json.fetch("sessions").fetch("sessions").to_h { |session| [session.fetch("sessionID"), session] }
turns_by_session = source_json.fetch("turns").fetch("turns").group_by { |turn| turn.fetch("sessionID") }
source_ids = source_json.fetch("sourceProvenance").fetch("sources").map { |source| source.fetch("id") }.to_set

abort("expected exactly 16 core role families") unless roles.length == 16 && roles.map { |role| role.fetch("id") }.uniq.length == 16

AUDIO_PROFILES = %w[
  clean
  low_volume
  high_volume_limited
  white_noise
  synthetic_cafe_noise
  mild_echo
].freeze
RATES = [145, 175, 210].freeze
NOISE_PROFILES = %w[white_noise synthetic_cafe_noise].freeze
MIXED_LANGUAGE_GLOBAL_INDICES = [7, 39, 71, 103].freeze
LONG_PAUSE_GLOBAL_INDICES = [2, 34, 66, 98].freeze
FILLER_GLOBAL_INDICES = [0, 32, 64, 96].freeze
SELF_CORRECTION_GLOBAL_INDICES = [3, 35, 67, 99].freeze
BASE_AUDIO_SEED = 24_083_100

def domain_for(role_id)
  case role_id
  when "robotics_research_engineer", "robotics_software_engineer", "embodied_ai_vla_engineer"
    "robotics_research"
  when "ai_research_scientist_phd"
    "academic_phd"
  when "computer_vision_engineer", "machine_learning_engineer", "applied_scientist",
       "ai_infrastructure_mlops_engineer", "data_scientist"
    "data_science"
  when "security_privacy_engineer"
    "cybersecurity"
  else
    "software_engineering"
  end
end

def expected_question_needle(turn)
  text = turn.fetch("rawUtterance").downcase
  needle = case turn.fetch("turnIndex")
           when 1 then "best prepares you for"
           when 3 then "evaluate your work against"
           when 4 then "hardest failure when you applied"
           when 6 then "one million production users"
           when 8 then "would you design"
           else
             abort("no reviewed expected-question needle for triggering turn #{turn.fetch('scenarioID')}")
           end
  abort("reviewed needle is not present in #{turn.fetch('scenarioID')}") unless text.include?(needle)
  needle
end

def decorated_text(text, global_index)
  decorated = text.dup
  decorated = "Um, #{decorated}" if FILLER_GLOBAL_INDICES.include?(global_index)
  decorated = "[[slnc 900]] #{decorated}" if LONG_PAUSE_GLOBAL_INDICES.include?(global_index)
  if SELF_CORRECTION_GLOBAL_INDICES.include?(global_index)
    decorated = "Actually, let me correct that framing. #{decorated}"
  end
  if MIXED_LANGUAGE_GLOBAL_INDICES.include?(global_index)
    decorated = "请用 English 回答：#{decorated}"
  end
  decorated
end

FileUtils.mkdir(output_directory, mode: 0o755)
scenario_manifest_entries = []
aggregate = {
  "roleFamilies" => 0,
  "candidateProfiles" => [],
  "opportunityContexts" => 0,
  "sessions" => 0,
  "turns" => 0,
  "triggerTurns" => 0,
  "rejectTurns" => 0,
  "rapidTransitions" => 0,
  "audioProfiles" => Hash.new(0),
  "voiceSlots" => Hash.new(0),
  "rates" => Hash.new(0),
  "dialoguePhenomena" => Hash.new(0)
}

roles.each_with_index do |role, role_index|
  role_id = role.fetch("id")
  source_session_id = "campaign-#{role_id}-01"
  source_session = sessions.fetch(source_session_id)
  profile = profiles.fetch(source_session.fetch("candidateProfileID"))
  opportunity = opportunities.fetch(source_session.fetch("opportunityContextID"))
  source_turns = turns_by_session.fetch(source_session_id).sort_by { |turn| turn.fetch("turnIndex") }

  abort("#{source_session_id} must contain exactly eight turns") unless source_turns.length == 8
  abort("#{source_session_id} must contain five triggers") unless source_turns.count { |turn| turn["expectedShouldTrigger"] } == 5
  abort("#{source_session_id} must contain three rejects") unless source_turns.count { |turn| !turn["expectedShouldTrigger"] } == 3
  abort("#{source_session_id} must contain one source rapid follow-up") unless source_turns.count { |turn| turn["rapidFollowUp"] } == 1
  abort("candidate profile does not declare role family #{role_id}") unless profile.fetch("roleFamilies").include?(role_id)
  abort("opportunity role family mismatch for #{role_id}") unless opportunity.fetch("roleFamilyID") == role_id
  referenced_sources = (role.fetch("sourceProvenanceIDs") + source_session.fetch("sourceProvenanceIDs")).uniq
  unknown_sources = referenced_sources.reject { |source_id| source_ids.include?(source_id) }
  abort("unknown source provenance for #{role_id}: #{unknown_sources.join(', ')}") unless unknown_sources.empty?

  verification_turns = source_turns.each_with_index.map do |turn, turn_index|
    global_index = (role_index * 8) + turn_index
    audio_profile = AUDIO_PROFILES.fetch(global_index % AUDIO_PROFILES.length)
    audio_profile = "clean" if MIXED_LANGUAGE_GLOBAL_INDICES.include?(global_index)
    transformed = {
      "text" => decorated_text(turn.fetch("rawUtterance"), global_index),
      "expectedShouldTrigger" => turn.fetch("expectedShouldTrigger"),
      "rate" => RATES.fetch((global_index + role_index) % RATES.length),
      "voiceSlot" => MIXED_LANGUAGE_GLOBAL_INDICES.include?(global_index) ? 3 : (global_index + turn_index) % 3,
      "audioProfile" => audio_profile,
      "sourceScenarioID" => turn.fetch("scenarioID"),
      "sourceChannel" => turn.fetch("channel"),
      "sourceSpeaker" => turn.fetch("speaker"),
      "recognitionPattern" => turn.fetch("recognitionPattern"),
      "dialoguePhenomena" => turn.fetch("dialoguePhenomena"),
      "sourceProvenanceIDs" => turn.fetch("sourceProvenanceIDs")
    }
    transformed["audioSeed"] = BASE_AUDIO_SEED + global_index + 1 if NOISE_PROFILES.include?(audio_profile)
    transformed["expectedQuestionNeedle"] = expected_question_needle(turn) if turn.fetch("expectedShouldTrigger")
    # The source corpus marks the arriving follow-up. The real runner marks the
    # preceding generation so that it can measure completion or cancellation.
    following_source_turn = source_turns[turn_index + 1]
    transformed["rapid"] = true if following_source_turn&.fetch("rapidFollowUp", false) == true

    aggregate["turns"] += 1
    if turn.fetch("expectedShouldTrigger")
      aggregate["triggerTurns"] += 1
    else
      aggregate["rejectTurns"] += 1
    end
    aggregate["rapidTransitions"] += 1 if transformed["rapid"] == true
    aggregate.fetch("audioProfiles")[audio_profile] += 1
    aggregate.fetch("voiceSlots")[transformed.fetch("voiceSlot").to_s] += 1
    aggregate.fetch("rates")[transformed.fetch("rate").to_s] += 1
    turn.fetch("dialoguePhenomena").each { |phenomenon| aggregate.fetch("dialoguePhenomena")[phenomenon] += 1 }
    transformed
  end

  expected_trigger_count = verification_turns.count { |turn| turn.fetch("expectedShouldTrigger") }
  expected_reject_count = verification_turns.length - expected_trigger_count
  expected_rapid_count = verification_turns.count { |turn| turn.fetch("rapid", false) }
  scenario = {
    "synthetic" => true,
    "runID" => "real-audio-role-#{format('%02d', role_index + 1)}",
    "provenance" => {
      "schemaVersion" => 1,
      "origin" => "project_authored_synthetic_fixture",
      "containsRealPersonalData" => false,
      "reviewedForRelease" => true,
      "sourceFixtureSessionID" => source_session_id,
      "sourceProvenanceIDs" => referenced_sources
    },
    "campaignMetadata" => {
      "roleFamilyID" => role_id,
      "roleFamily" => role.fetch("title"),
      "seniority" => opportunity.fetch("seniority"),
      "sourceSessionID" => source_session_id,
      "playbackChannel" => "systemAudio",
      "audioOrigin" => "local_synthetic_say_and_ffmpeg_only"
    },
    "asrProvider" => "local_parakeet",
    "answerProvider" => "local_qwen",
    "qwenModel" => "qwen3.5:4b",
    "diagnosticTraceMode" => "metadataOnly",
    "candidateProfile" => {
      "id" => "synthetic-#{profile.fetch('id')}",
      "sourceProfileID" => profile.fetch("id"),
      "displayName" => "Synthetic Candidate",
      "domain" => domain_for(role_id),
      "evidence" => profile.fetch("verifiedStatements")
    },
    "opportunityContext" => {
      "id" => "synthetic-#{opportunity.fetch('id')}",
      "sourceOpportunityContextID" => opportunity.fetch("id"),
      "title" => opportunity.fetch("title"),
      "evidence" => opportunity.fetch("opportunityEvidence")
    },
    "expectedSessionCount" => 1,
    "expectedTurnCount" => verification_turns.length,
    "expectedTriggerCount" => expected_trigger_count,
    "expectedRejectCount" => expected_reject_count,
    "expectedVisibleCountMinimum" => expected_trigger_count - expected_rapid_count,
    "expectedVisibleCountMaximum" => expected_trigger_count,
    "expectedRapidTransitionCount" => expected_rapid_count,
    "sessions" => [{
      "id" => "real-audio-#{role_id}-01",
      "turns" => verification_turns
    }]
  }

  filename = "role-#{format('%02d', role_index + 1)}-#{role_id}.json"
  serialized = JSON.pretty_generate(scenario) + "\n"
  File.binwrite(File.join(output_directory, filename), serialized)
  scenario_manifest_entries << {
    "filename" => filename,
    "roleFamilyID" => role_id,
    "candidateProfileID" => profile.fetch("id"),
    "opportunityContextID" => opportunity.fetch("id"),
    "sessionID" => source_session_id,
    "turns" => verification_turns.length,
    "triggerTurns" => expected_trigger_count,
    "rejectTurns" => expected_reject_count,
    "rapidTransitions" => expected_rapid_count,
    "sha256" => Digest::SHA256.hexdigest(serialized)
  }
  aggregate["roleFamilies"] += 1
  aggregate.fetch("candidateProfiles") << profile.fetch("id")
  aggregate["opportunityContexts"] += 1
  aggregate["sessions"] += 1
end

aggregate["candidateProfiles"] = aggregate.fetch("candidateProfiles").uniq.sort
aggregate["audioProfiles"] = aggregate.fetch("audioProfiles").sort.to_h
aggregate["voiceSlots"] = aggregate.fetch("voiceSlots").sort.to_h
aggregate["rates"] = aggregate.fetch("rates").sort.to_h
aggregate["dialoguePhenomena"] = aggregate.fetch("dialoguePhenomena").sort.to_h

abort("generated real-audio matrix turn total mismatch") unless aggregate.fetch("turns") == 128
abort("generated real-audio matrix trigger total mismatch") unless aggregate.fetch("triggerTurns") == 80
abort("generated real-audio matrix reject total mismatch") unless aggregate.fetch("rejectTurns") == 48
abort("generated real-audio matrix rapid total mismatch") unless aggregate.fetch("rapidTransitions") == 16
abort("generated real-audio matrix candidate total mismatch") unless aggregate.fetch("candidateProfiles").length == 10
abort("generated real-audio matrix audio profile coverage mismatch") unless aggregate.fetch("audioProfiles").keys == AUDIO_PROFILES.sort
abort("generated real-audio matrix voice coverage mismatch") unless aggregate.fetch("voiceSlots").keys == %w[0 1 2 3]
abort("generated real-audio matrix rate coverage mismatch") unless aggregate.fetch("rates").keys == RATES.map(&:to_s).sort

manifest = {
  "synthetic" => true,
  "schemaVersion" => 1,
  "campaignFixtureVersion" => "2026-08-31",
  "generator" => "scripts/generate_real_audio_campaign_fixtures.rb",
  "audioSeedBase" => BASE_AUDIO_SEED,
  "sourceFiles" => source_data.transform_values do |value|
    {
      "path" => "Tests/HirevaTests/Fixtures/InterviewCampaign/#{value.fetch('filename')}",
      "sha256" => Digest::SHA256.hexdigest(value.fetch("data"))
    }
  end,
  "coverage" => aggregate,
  "scenarios" => scenario_manifest_entries
}
File.binwrite(File.join(output_directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

puts "REAL_AUDIO_FIXTURES=generated"
puts "REAL_AUDIO_ROLE_FAMILIES=#{aggregate.fetch('roleFamilies')}"
puts "REAL_AUDIO_CANDIDATE_PROFILES=#{aggregate.fetch('candidateProfiles').length}"
puts "REAL_AUDIO_OPPORTUNITY_CONTEXTS=#{aggregate.fetch('opportunityContexts')}"
puts "REAL_AUDIO_SESSIONS=#{aggregate.fetch('sessions')}"
puts "REAL_AUDIO_TURNS=#{aggregate.fetch('turns')}"
puts "REAL_AUDIO_TRIGGERS=#{aggregate.fetch('triggerTurns')}"
puts "REAL_AUDIO_REJECTS=#{aggregate.fetch('rejectTurns')}"
puts "REAL_AUDIO_RAPID_TRANSITIONS=#{aggregate.fetch('rapidTransitions')}"
