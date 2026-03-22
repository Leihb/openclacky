#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky PDF Parser — CLI interface
#
# Usage:
#   ruby pdf_parser.rb <file_path>
#
# Output:
#   stdout — extracted text content (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# This file lives in ~/.clacky/parsers/ and can be modified by the LLM
# to add new capabilities (e.g. OCR for scanned PDFs).
#
# VERSION: 1

require "open3"

MIN_CONTENT_BYTES = 20

def try_pdftotext(path)
  stdout, _stderr, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", path, "-")
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # pdftotext not installed
end

def try_pdfplumber(path)
  script = <<~PYTHON
    import sys, pdfplumber
    with pdfplumber.open(sys.argv[1]) as pdf:
        pages = []
        for i, page in enumerate(pdf.pages, 1):
            t = page.extract_text()
            if t and t.strip():
                pages.append(f"--- Page {i} ---\\n{t.strip()}")
        print("\\n\\n".join(pages))
  PYTHON

  stdout, _stderr, status = Open3.capture3("python3", "-c", script, path)
  return nil unless status.success?
  text = stdout.strip
  return nil if text.bytesize < MIN_CONTENT_BYTES
  text
rescue Errno::ENOENT
  nil # python3 not available
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby pdf_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

text = try_pdftotext(path) || try_pdfplumber(path)

if text
  print text
  exit 0
else
  warn "Could not extract text from PDF."
  warn "Tip: install poppler for text-based PDFs: brew install poppler"
  warn "For scanned PDFs, consider adding OCR support (e.g. tesseract)."
  exit 1
end
