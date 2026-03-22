#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky DOCX Parser — CLI interface
#
# Usage:
#   ruby docx_parser.rb <file_path>
#
# Output:
#   stdout — extracted text in Markdown (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# Dependencies: rubyzip gem (gem install rubyzip)
#
# This file lives in ~/.clacky/parsers/ and can be modified by the LLM.
#
# VERSION: 1

require "zip"
require "rexml/document"
require "stringio"

def read_document_xml(body)
  Zip::File.open_buffer(StringIO.new(body)) do |zip|
    entry = zip.find_entry("word/document.xml")
    raise "Could not extract content — possibly encrypted or invalid format" unless entry
    entry.get_input_stream.read
  end
end

def read_numbering(body)
  result = {}
  Zip::File.open_buffer(StringIO.new(body)) do |zip|
    entry = zip.find_entry("word/numbering.xml")
    break unless entry
    doc = REXML::Document.new(entry.get_input_stream.read)
    REXML::XPath.each(doc, "//w:abstractNum") do |an|
      id = an.attributes["w:abstractNumId"]
      levels = {}
      REXML::XPath.each(an, "w:lvl") do |lvl|
        ilvl = lvl.attributes["w:ilvl"].to_i
        fmt  = REXML::XPath.first(lvl, "w:numFmt")&.attributes&.[]("w:val")
        levels[ilvl] = { fmt: fmt || "bullet" }
      end
      result[id] = levels
    end
  end
  result
rescue
  {}
end

def read_styles(body)
  result = {}
  Zip::File.open_buffer(StringIO.new(body)) do |zip|
    entry = zip.find_entry("word/styles.xml")
    break unless entry
    doc = REXML::Document.new(entry.get_input_stream.read)
    REXML::XPath.each(doc, "//w:style") do |s|
      sid  = s.attributes["w:styleId"]
      name = REXML::XPath.first(s, "w:name")&.attributes&.[]("w:val").to_s
      if name =~ /^heading (\d)/i
        result[sid] = { heading: $1.to_i }
      end
    end
  end
  result
rescue
  {}
end

def extract_runs(para_node)
  parts = []
  REXML::XPath.each(para_node, "w:r") do |run|
    rpr  = REXML::XPath.first(run, "w:rPr")
    bold = REXML::XPath.first(rpr, "w:b") if rpr
    text = REXML::XPath.match(run, "w:t").map(&:text).compact.join
    next if text.empty?
    parts << (bold ? "**#{text}**" : text)
  end
  parts.join
end

def parse_paragraph(node, styles, numbering)
  ppr    = REXML::XPath.first(node, "w:pPr")
  style  = REXML::XPath.first(ppr, "w:pStyle")&.attributes&.[]("w:val") if ppr
  num_pr = REXML::XPath.first(ppr, "w:numPr") if ppr

  text = extract_runs(node)
  return nil if text.strip.empty?

  if style && styles[style]
    level = styles[style][:heading]
    return "#{"#" * level} #{text}"
  end

  if num_pr
    ilvl = REXML::XPath.first(num_pr, "w:ilvl")&.attributes&.[]("w:val").to_i
    indent = "  " * ilvl
    return "#{indent}- #{text}"
  end

  text
end

def parse_table(tbl_node)
  rows = []
  REXML::XPath.each(tbl_node, "w:tr") do |tr|
    cells = REXML::XPath.match(tr, "w:tc").map do |tc|
      REXML::XPath.match(tc, ".//w:t").map(&:text).compact.join(" ").strip
    end
    rows << cells
  end
  return "" if rows.empty?

  col_count = rows.map(&:size).max
  lines = []
  rows.each_with_index do |row, i|
    padded = row + [""] * [col_count - row.size, 0].max
    lines << "| #{padded.join(" | ")} |"
    lines << "|#{" --- |" * col_count}" if i == 0
  end
  lines.join("\n")
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby docx_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

begin
  body   = File.binread(path)
  xml    = read_document_xml(body)
  doc    = REXML::Document.new(xml)
  numbering = read_numbering(body)
  styles    = read_styles(body)

  lines = []
  REXML::XPath.each(doc, "//w:body/*") do |node|
    case node.name
    when "p"
      line = parse_paragraph(node, styles, numbering)
      lines << line unless line.nil?
    when "tbl"
      lines << parse_table(node)
    end
  end

  result = lines.join("\n").strip
  if result.empty?
    warn "Document appears to be empty"
    exit 1
  end

  print result
  exit 0
rescue => e
  warn "Failed to parse DOCX: #{e.message}"
  warn "Tip: ensure rubyzip is installed: gem install rubyzip"
  exit 1
end
