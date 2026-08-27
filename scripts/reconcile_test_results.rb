#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "rexml/document"
require "rexml/xpath"

def usage
  warn "usage: #{File.basename($PROGRAM_NAME)} <swift-test-list.log> <xunit.xml> <status.csv> <release-test-prerequisites.tsv>"
  exit 2
end

def occurrences(values)
  values.each_with_object(Hash.new(0)) { |value, counts| counts[value] += 1 }
end

usage unless ARGV.length == 4

list_path, xunit_path, output_path, prerequisite_path = ARGV
abort("status output already exists: #{output_path}") if File.exist?(output_path)

specifier_pattern = /\A[A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z_][A-Za-z0-9_]*\/.+\z/
discovered = File.readlines(list_path, chomp: true)
  .map(&:strip)
  .select { |line| specifier_pattern.match?(line) }

document = REXML::Document.new(File.read(xunit_path))
results = []
REXML::XPath.each(document, "//testcase") do |testcase|
  classname = testcase.attributes["classname"].to_s
  name = testcase.attributes["name"].to_s
  failures = testcase.get_elements("failure")
  errors = testcase.get_elements("error")
  skipped = testcase.get_elements("skipped")
  status = if errors.any?
             "ERROR"
           elsif failures.any?
             "FAIL"
           elsif skipped.any?
             "SKIP"
           else
             "PASS"
           end
  results << {
    id: "#{classname}/#{name}",
    suite: classname,
    test: name,
    status: status,
    duration: testcase.attributes["time"].to_s,
    assertion_issues: failures.length + errors.length
  }
end

duplicate_discoveries = occurrences(discovered).select { |_, count| count > 1 }.keys.sort
duplicate_results = occurrences(results.map { |result| result[:id] }).select { |_, count| count > 1 }.keys.sort
result_by_id = results.to_h { |result| [result[:id], result] }
discovered_ids = discovered.to_h { |id| [id, true] }
missing = discovered.reject { |id| result_by_id.key?(id) }.uniq.sort
unexpected = results.map { |result| result[:id] }.reject { |id| discovered_ids.key?(id) }.uniq.sort

rows = discovered.uniq.sort.map do |id|
  result_by_id.fetch(id) do
    suite, test = id.split("/", 2)
    {
      id: id,
      suite: suite,
      test: test,
      status: "NOT_REPORTED",
      duration: "",
      assertion_issues: 0
    }
  end
end
unexpected.each do |id|
  result = result_by_id.fetch(id).dup
  result[:status] = "UNREGISTERED_RESULT"
  rows << result
end

prerequisite_table = CSV.read(prerequisite_path, headers: true, col_sep: "\t")
prerequisites = prerequisite_table.map(&:to_h)
required_headers = %w[check_id gate lane status_policy privacy_or_isolation_constraint]
missing_headers = required_headers.reject { |header| prerequisite_table.headers&.include?(header) }
required_prerequisites = prerequisites.select do |row|
  row.fetch("status_policy", "") == "REQUIRED_IN_RECONCILED_RUN"
end
required_ids = required_prerequisites.map { |row| row.fetch("check_id", "").strip }
duplicate_prerequisite_ids = occurrences(prerequisites.map { |row| row.fetch("check_id", "").strip })
  .select { |id, count| !id.empty? && count > 1 }
  .keys
  .sort
blank_prerequisite_ids = prerequisites.each_index.select do |index|
  prerequisites[index].fetch("check_id", "").strip.empty?
end
unsupported_policies = prerequisites.map { |row| row.fetch("status_policy", "").strip }
  .reject { |policy| %w[REQUIRED_IN_RECONCILED_RUN NOT_RUN_POLICY_NO_SECRET].include?(policy) }
  .uniq
  .sort
required_missing_discovery = required_ids.reject { |id| discovered_ids.key?(id) }.uniq.sort
required_missing_results = required_ids.reject { |id| result_by_id.key?(id) }.uniq.sort
required_nonpassing = required_ids.each_with_object([]) do |id, values|
  result = result_by_id[id]
  values << "#{id}=#{result[:status]}" unless result.nil? || result[:status] == "PASS"
end.sort
required_passed = required_ids.count { |id| result_by_id[id]&.fetch(:status, nil) == "PASS" }

CSV.open(output_path, "wb", force_quotes: true, row_sep: "\n") do |csv|
  csv << %w[test_id suite test status duration_seconds assertion_issues]
  rows.sort_by { |row| row[:id] }.each do |row|
    csv << [
      row[:id],
      row[:suite],
      row[:test],
      row[:status],
      row[:duration],
      row[:assertion_issues]
    ]
  end
end

counts = results.group_by { |result| result[:status] }.transform_values(&:length)
assertion_issues = results.sum { |result| result[:assertion_issues] }
puts [
  "discovered=#{discovered.length}",
  "reported=#{results.length}",
  "passed=#{counts.fetch('PASS', 0)}",
  "failed=#{counts.fetch('FAIL', 0)}",
  "errors=#{counts.fetch('ERROR', 0)}",
  "skipped=#{counts.fetch('SKIP', 0)}",
  "assertion_issues=#{assertion_issues}",
  "missing=#{missing.length}",
  "unexpected=#{unexpected.length}",
  "duplicate_discoveries=#{duplicate_discoveries.length}",
  "duplicate_results=#{duplicate_results.length}",
  "required_manifest_checks=#{required_ids.length}",
  "required_manifest_passed=#{required_passed}"
].join(" ")
puts "status_table=#{output_path}"

problems = []
problems << "discovery reported zero tests" if discovered.empty?
problems << "xUnit reported zero test cases" if results.empty?
problems << "failed test cases: #{counts.fetch('FAIL', 0)}" if counts.fetch("FAIL", 0).positive?
problems << "error test cases: #{counts.fetch('ERROR', 0)}" if counts.fetch("ERROR", 0).positive?
problems << "skipped test cases: #{counts.fetch('SKIP', 0)}" if counts.fetch("SKIP", 0).positive?
problems << "missing xUnit results: #{missing.join(', ')}" if missing.any?
problems << "unregistered xUnit results: #{unexpected.join(', ')}" if unexpected.any?
problems << "duplicate discoveries: #{duplicate_discoveries.join(', ')}" if duplicate_discoveries.any?
problems << "duplicate xUnit results: #{duplicate_results.join(', ')}" if duplicate_results.any?
problems << "prerequisite manifest missing headers: #{missing_headers.join(', ')}" if missing_headers.any?
problems << "blank prerequisite check_id rows: #{blank_prerequisite_ids.map { |index| index + 2 }.join(', ')}" if blank_prerequisite_ids.any?
problems << "duplicate prerequisite check_ids: #{duplicate_prerequisite_ids.join(', ')}" if duplicate_prerequisite_ids.any?
problems << "unsupported prerequisite status policies: #{unsupported_policies.join(', ')}" if unsupported_policies.any?
problems << "required manifest checks missing from discovery: #{required_missing_discovery.join(', ')}" if required_missing_discovery.any?
problems << "required manifest checks missing from xUnit: #{required_missing_results.join(', ')}" if required_missing_results.any?
problems << "required manifest checks did not pass: #{required_nonpassing.join(', ')}" if required_nonpassing.any?

unless problems.empty?
  problems.each { |problem| warn "reconciliation failure: #{problem}" }
  exit 1
end
