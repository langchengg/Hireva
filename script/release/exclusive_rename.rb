#!/usr/bin/env ruby
# frozen_string_literal: true

require "fiddle/import"

module DarwinRename
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int renameatx_np(int, const char *, int, const char *, unsigned int)"
end

AT_FDCWD = -2
RENAME_EXCL = 0x00000004

unless ARGV.length == 2
  warn "Usage: exclusive_rename.rb /existing/source /nonexistent/destination"
  exit 2
end

source, destination = ARGV
unless File.exist?(source) && !File.symlink?(source)
  warn "error: exclusive rename source must exist and must not be a symlink: #{source}"
  exit 1
end
if File.exist?(destination) || File.symlink?(destination)
  warn "error: exclusive rename destination already exists: #{destination}"
  exit 1
end

result = DarwinRename.renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, RENAME_EXCL)
unless result.zero?
  error = SystemCallError.new("renameatx_np(RENAME_EXCL)", Fiddle.last_error)
  warn "error: #{error.message}: #{destination}"
  exit 1
end

unless !File.exist?(source) && File.exist?(destination) && !File.symlink?(destination)
  warn "error: exclusive rename completed with an unexpected filesystem state"
  exit 1
end
