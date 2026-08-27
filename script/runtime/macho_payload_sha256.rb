#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"

MACH_HEADER_64_SIZE = 32
MH_MAGIC_64 = 0xfeedfacf
CPU_TYPE_ARM64 = 0x0100000c
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1d
SEGMENT_COMMAND_64_SIZE = 72
SECTION_64_SIZE = 80
ZERO_FILL_SECTION_TYPES = [0x1, 0xc, 0x12].freeze
MACHO_PAGE_SIZE = 0x4000
MAX_MACHO_FILE_SIZE_BYTES = 64 * 1024 * 1024
MAX_LOAD_COMMANDS = 1024
MAX_SECTIONS = 16_384
MAX_CODE_SIGNATURE_BLOBS = 64
CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0
CANONICAL_DOMAIN = "hireva-thin-arm64-macho-canonical-v1\0".b

def fail_with(message)
  warn "error: #{message}"
  exit 1
end

def read_u32(data, offset)
  bytes = data.byteslice(offset, 4)
  fail_with("truncated Mach-O uint32 at offset #{offset}") unless bytes&.bytesize == 4
  bytes.unpack1("V")
end

def read_u64(data, offset)
  bytes = data.byteslice(offset, 8)
  fail_with("truncated Mach-O uint64 at offset #{offset}") unless bytes&.bytesize == 8
  bytes.unpack1("Q<")
end

def read_be_u32(data, offset)
  bytes = data.byteslice(offset, 4)
  fail_with("truncated code-signature uint32 at offset #{offset}") unless bytes&.bytesize == 4
  bytes.unpack1("N")
end

def write_u32(data, offset, value)
  data[offset, 4] = [value].pack("V")
end

def write_u64(data, offset, value)
  data[offset, 8] = [value].pack("Q<")
end

def macho_name(bytes)
  terminator = bytes.index("\0")
  return bytes unless terminator

  trailing = bytes.byteslice(terminator + 1, bytes.bytesize - terminator - 1)
  fail_with("Mach-O name field has nonzero bytes after its terminator") unless trailing.bytes.all?(&:zero?)
  bytes.byteslice(0, terminator)
end

def round_up(value, alignment)
  ((value + alignment - 1) / alignment) * alignment
end

def validate_superblob(data, signature_offset, signature_size)
  fail_with("code signature is too small for an embedded-signature SuperBlob") if signature_size < 12
  fail_with("code signature is not an embedded-signature SuperBlob") unless \
    read_be_u32(data, signature_offset) == CSMAGIC_EMBEDDED_SIGNATURE

  declared_length = read_be_u32(data, signature_offset + 4)
  entry_count = read_be_u32(data, signature_offset + 8)
  fail_with("code-signature SuperBlob has no entries") if entry_count.zero?
  if entry_count > MAX_CODE_SIGNATURE_BLOBS
    fail_with("code-signature SuperBlob exceeds the reviewed 64-entry limit")
  end
  fail_with("code-signature SuperBlob length exceeds LC_CODE_SIGNATURE") if declared_length > signature_size

  index_size = entry_count * 8
  index_end = 12 + index_size
  if declared_length < index_end || index_end > signature_size
    fail_with("code-signature SuperBlob index exceeds its declared length")
  end

  ranges = []
  entry_count.times do |index|
    entry_offset = signature_offset + 12 + index * 8
    blob_offset = read_be_u32(data, entry_offset + 4)
    fail_with("code-signature blob overlaps the SuperBlob index") if blob_offset < index_end
    fail_with("truncated nested code-signature blob header") if blob_offset + 8 > declared_length

    blob_length = read_be_u32(data, signature_offset + blob_offset + 4)
    fail_with("nested code-signature blob is shorter than its header") if blob_length < 8
    blob_end = blob_offset + blob_length
    fail_with("nested code-signature blob exceeds the SuperBlob length") if blob_end > declared_length
    ranges << (blob_offset...blob_end)
  end

  ranges.sort_by(&:begin).each_cons(2) do |left, right|
    fail_with("nested code-signature blobs overlap") if left.end > right.begin
  end
end

path = ARGV.fetch(0) { fail_with("expected one Mach-O path") }
fail_with("expected one Mach-O path") unless ARGV.length == 1
fail_with("Mach-O path must be a regular non-symlink file") unless File.file?(path) && !File.symlink?(path)

begin
  open_flags = File::RDONLY | File::NOFOLLOW
  data = File.open(path, open_flags) do |file|
    expected_size = file.stat.size
    if expected_size > MAX_MACHO_FILE_SIZE_BYTES
      fail_with("Mach-O file exceeds the reviewed 64 MiB parser limit")
    end
    bytes = file.read(expected_size + 1)
    fail_with("Mach-O file changed size while being read") unless bytes&.bytesize == expected_size
    fail_with("Mach-O file changed size while being read") unless file.stat.size == expected_size
    bytes
  end
rescue SystemCallError => error
  fail_with("unable to read Mach-O file: #{error.message}")
end
fail_with("Mach-O file is smaller than mach_header_64") if data.bytesize < MACH_HEADER_64_SIZE
fail_with("expected little-endian 64-bit Mach-O") unless read_u32(data, 0) == MH_MAGIC_64
fail_with("expected arm64 Mach-O") unless read_u32(data, 4) == CPU_TYPE_ARM64
fail_with("expected arm64 Mach-O subtype") unless (read_u32(data, 8) & 0x00ff_ffff).zero?

ncmds = read_u32(data, 16)
sizeofcmds = read_u32(data, 20)
fail_with("Mach-O has no load commands") if ncmds.zero? || sizeofcmds.zero?
fail_with("Mach-O exceeds the reviewed 1024-load-command limit") if ncmds > MAX_LOAD_COMMANDS
commands_end = MACH_HEADER_64_SIZE + sizeofcmds
fail_with("Mach-O load commands exceed file bounds") if commands_end > data.bytesize

commands = []
code_signature = nil
linkedit_index = nil
linkedit_fileoff = nil
linkedit_vmsize = nil
linkedit_filesize = nil
file_backed_section_offsets = []
file_backed_section_ends = []
segment_ranges = []
total_section_count = 0
cursor = MACH_HEADER_64_SIZE

ncmds.times do |index|
  fail_with("truncated Mach-O load command header") if cursor + 8 > commands_end
  command = read_u32(data, cursor)
  command_size = read_u32(data, cursor + 4)
  if command_size < 8 || (command_size % 8) != 0 || cursor + command_size > commands_end
    fail_with("invalid Mach-O load command size at index #{index}")
  end

  bytes = data.byteslice(cursor, command_size).dup
  if command == LC_CODE_SIGNATURE
    fail_with("multiple LC_CODE_SIGNATURE commands are unsupported") if code_signature
    fail_with("invalid LC_CODE_SIGNATURE size") unless command_size == 16
    code_signature = [read_u32(bytes, 8), read_u32(bytes, 12)]
  elsif command == LC_SEGMENT_64
    fail_with("truncated LC_SEGMENT_64") if command_size < SEGMENT_COMMAND_64_SIZE
    segment_name = macho_name(bytes.byteslice(8, 16))
    segment_vmsize = read_u64(bytes, 32)
    segment_fileoff = read_u64(bytes, 40)
    segment_filesize = read_u64(bytes, 48)
    segment_file_end = segment_fileoff + segment_filesize
    fail_with("Mach-O segment file size exceeds virtual size") if segment_filesize > segment_vmsize
    if segment_filesize.positive? && segment_file_end > data.bytesize
      fail_with("file-backed Mach-O segment exceeds file bounds")
    end
    if segment_filesize.positive?
      segment_ranges << { name: segment_name, start: segment_fileoff, end: segment_file_end }
    end
    section_count = read_u32(bytes, 64)
    total_section_count += section_count
    if total_section_count > MAX_SECTIONS
      fail_with("Mach-O exceeds the reviewed 16384-section limit")
    end
    minimum_size = SEGMENT_COMMAND_64_SIZE + section_count * SECTION_64_SIZE
    fail_with("LC_SEGMENT_64 size differs from its section table") unless minimum_size == command_size

    if segment_name == "__LINKEDIT"
      fail_with("multiple __LINKEDIT segments are unsupported") if linkedit_index
      linkedit_index = commands.length
      linkedit_fileoff = segment_fileoff
      linkedit_vmsize = segment_vmsize
      linkedit_filesize = segment_filesize
    end

    section_count.times do |section_index|
      section_offset = SEGMENT_COMMAND_64_SIZE + section_index * SECTION_64_SIZE
      section_size = read_u64(bytes, section_offset + 40)
      file_offset = read_u32(bytes, section_offset + 48)
      section_type = read_u32(bytes, section_offset + 64) & 0xff
      next if section_size.zero? || ZERO_FILL_SECTION_TYPES.include?(section_type)
      fail_with("file-backed Mach-O section has zero file offset") if file_offset.zero?
      file_end = file_offset + section_size
      fail_with("file-backed Mach-O section exceeds file bounds") if file_end > data.bytesize
      if segment_filesize.zero? || file_offset < segment_fileoff || file_end > segment_file_end
        fail_with("file-backed Mach-O section exceeds its segment range")
      end
      file_backed_section_offsets << file_offset
      file_backed_section_ends << file_end
    end
  end

  commands << { command: command, bytes: bytes }
  cursor += command_size
end

fail_with("load command byte count differs from sizeofcmds") unless cursor == commands_end
fail_with("Mach-O is missing __LINKEDIT") unless linkedit_index && linkedit_fileoff && linkedit_vmsize && linkedit_filesize
fail_with("Mach-O has no file-backed sections") if file_backed_section_offsets.empty?
content_start = file_backed_section_offsets.min
max_file_backed_end = file_backed_section_ends.max
fail_with("Mach-O sections overlap load commands") if content_start < commands_end
first_nonzero_padding = data.index(/[^\x00]/n, commands_end)
if first_nonzero_padding && first_nonzero_padding < content_start
  fail_with("nonzero bytes found in Mach-O load-command padding")
end

segment_ranges.reject { |range| range[:name] == "__LINKEDIT" }.each do |range|
  if range[:end] > linkedit_fileoff
    fail_with("non-__LINKEDIT Mach-O segment overlaps __LINKEDIT")
  end
end
segment_ranges.sort_by { |range| [range[:start], range[:end]] }.each_cons(2) do |left, right|
  fail_with("file-backed Mach-O segments overlap") if left[:end] > right[:start]
end

canonical_end = data.bytesize
linkedit_file_end = linkedit_fileoff + linkedit_filesize
fail_with("__LINKEDIT must cover the physical end of the Mach-O file") unless linkedit_file_end == data.bytesize
fail_with("__LINKEDIT file offset is not aligned to the arm64 page size") unless \
  (linkedit_fileoff % MACHO_PAGE_SIZE).zero?
expected_linkedit_vmsize = round_up(linkedit_filesize, MACHO_PAGE_SIZE)
fail_with("__LINKEDIT virtual size is not the arm64 page-rounded file size") unless \
  linkedit_vmsize == expected_linkedit_vmsize
if code_signature
  signature_offset, signature_size = code_signature
  signature_end = signature_offset + signature_size
  fail_with("code signature blob exceeds Mach-O bounds") if signature_end > data.bytesize
  fail_with("code signature blob must be the final Mach-O payload") unless signature_end == data.bytesize
  fail_with("code signature must reside within __LINKEDIT") if signature_offset < linkedit_fileoff || signature_end > linkedit_file_end
  fail_with("code signature overlaps file-backed section content") if signature_offset < max_file_backed_end
  validate_superblob(data, signature_offset, signature_size)
  canonical_end = signature_offset
end
fail_with("file-backed Mach-O section exceeds canonical payload") if max_file_backed_end > canonical_end
fail_with("__LINKEDIT starts beyond canonical Mach-O end") if linkedit_fileoff > canonical_end

canonical_commands = commands.reject { |entry| entry[:command] == LC_CODE_SIGNATURE }
linkedit_command = canonical_commands.find do |entry|
  entry[:command] == LC_SEGMENT_64 && macho_name(entry[:bytes].byteslice(8, 16)) == "__LINKEDIT"
end
fail_with("canonical command set is missing __LINKEDIT") unless linkedit_command
canonical_linkedit_filesize = canonical_end - linkedit_fileoff
write_u64(linkedit_command[:bytes], 32, round_up(canonical_linkedit_filesize, MACHO_PAGE_SIZE))
write_u64(linkedit_command[:bytes], 48, canonical_linkedit_filesize)

canonical_header = data.byteslice(0, MACH_HEADER_64_SIZE).dup
canonical_sizeofcmds = canonical_commands.sum { |entry| entry[:bytes].bytesize }
write_u32(canonical_header, 16, canonical_commands.length)
write_u32(canonical_header, 20, canonical_sizeofcmds)
canonical_padding_size = content_start - MACH_HEADER_64_SIZE - canonical_sizeofcmds
fail_with("canonical load commands overlap section content") if canonical_padding_size.negative?

digest = Digest::SHA256.new
digest << CANONICAL_DOMAIN
digest << canonical_header
canonical_commands.each { |entry| digest << entry[:bytes] }
zero_chunk = "\0".b * 65_536
remaining_padding = canonical_padding_size
while remaining_padding.positive?
  chunk_size = [remaining_padding, zero_chunk.bytesize].min
  digest << zero_chunk.byteslice(0, chunk_size)
  remaining_padding -= chunk_size
end
payload_offset = content_start
while payload_offset < canonical_end
  chunk_size = [canonical_end - payload_offset, 1_048_576].min
  digest << data.byteslice(payload_offset, chunk_size)
  payload_offset += chunk_size
end
puts digest.hexdigest
