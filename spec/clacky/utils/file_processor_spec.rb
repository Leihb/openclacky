# frozen_string_literal: true

require "tmpdir"

RSpec.describe Clacky::Utils::FileProcessor do
  # ---------------------------------------------------------------------------
  # .save — store only, no parsing
  # ---------------------------------------------------------------------------
  describe ".save" do
    it "writes bytes to disk and returns name + path" do
      result = described_class.save(body: "hello", filename: "notes.txt")
      expect(result[:name]).to eq("notes.txt")
      expect(File.exist?(result[:path])).to be true
      expect(File.read(result[:path])).to eq("hello")
    end

    it "sanitizes unsafe filename characters" do
      result = described_class.save(body: "", filename: "../../../etc/passwd")
      expect(result[:name]).not_to include("/")
      expect(File.exist?(result[:path])).to be true
    end

    it "two saves with same filename produce different paths" do
      r1 = described_class.save(body: "a", filename: "doc.pdf")
      r2 = described_class.save(body: "b", filename: "doc.pdf")
      expect(r1[:path]).not_to eq(r2[:path])
    end

    it "does NOT parse the file" do
      expect(Clacky::Utils::ParserManager).not_to receive(:parse)
      described_class.save(body: "%PDF-1.4", filename: "test.pdf")
    end
  end

  # ---------------------------------------------------------------------------
  # .process_path — parse an already-saved file
  # ---------------------------------------------------------------------------
  describe ".process_path" do
    context "when parser succeeds" do
      it "returns FileRef with preview_path written to disk" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "test.pdf")
          File.binwrite(path, "%PDF-1.4")

          allow(Clacky::Utils::ParserManager).to receive(:parse).with(path)
            .and_return({ success: true, text: "extracted text", error: nil, parser_path: nil })

          ref = described_class.process_path(path)
          expect(ref.preview_path).to eq("#{path}.preview.md")
          expect(File.read(ref.preview_path)).to eq("extracted text")
          expect(ref.parse_error).to be_nil
        end
      end

      it "uses filename as display name" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "report.docx")
          File.binwrite(path, "bytes")

          allow(Clacky::Utils::ParserManager).to receive(:parse)
            .and_return({ success: true, text: "content", error: nil, parser_path: nil })

          ref = described_class.process_path(path)
          expect(ref.name).to eq("report.docx")
        end
      end

      it "accepts explicit name override" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "abc123_report.docx")
          File.binwrite(path, "bytes")

          allow(Clacky::Utils::ParserManager).to receive(:parse)
            .and_return({ success: true, text: "content", error: nil, parser_path: nil })

          ref = described_class.process_path(path, name: "report.docx")
          expect(ref.name).to eq("report.docx")
        end
      end
    end

    context "when parser fails" do
      it "returns FileRef with parse_error and parser_path, no preview" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "broken.pdf")
          File.binwrite(path, "not a real pdf")

          allow(Clacky::Utils::ParserManager).to receive(:parse).with(path)
            .and_return({ success: false, text: nil,
                          error: "pdftotext failed", parser_path: "/home/.clacky/parsers/pdf_parser.rb" })

          ref = described_class.process_path(path)
          expect(ref.preview_path).to be_nil
          expect(ref.parse_error).to eq("pdftotext failed")
          expect(ref.parser_path).to eq("/home/.clacky/parsers/pdf_parser.rb")
          expect(ref.parse_failed?).to be true
        end
      end
    end

    context "with image files" do
      it "skips parsing and returns FileRef with no preview" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "photo.png")
          File.binwrite(path, "\x89PNG\r\n\x1a\n")

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(path)
          expect(ref.type).to eq(:image)
          expect(ref.preview_path).to be_nil
          expect(ref.parse_error).to be_nil
        end
      end
    end

    context "with zip files" do
      it "generates directory listing preview without calling ParserManager" do
        require "zip"
        Dir.mktmpdir do |dir|
          zip_path = File.join(dir, "archive.zip")
          Zip::OutputStream.open(zip_path) do |z|
            z.put_next_entry("readme.txt")
            z.write("hello")
          end

          expect(Clacky::Utils::ParserManager).not_to receive(:parse)

          ref = described_class.process_path(zip_path)
          expect(ref.type).to eq(:zip)
          expect(ref.preview_path).to end_with(".preview.md")
          expect(File.read(ref.preview_path)).to include("readme.txt")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .process — save + process_path combined
  # ---------------------------------------------------------------------------
  describe ".process" do
    it "saves file to disk and returns parsed FileRef" do
      allow(Clacky::Utils::ParserManager).to receive(:parse)
        .and_return({ success: true, text: "the content", error: nil, parser_path: nil })

      ref = described_class.process(body: "%PDF-1.4", filename: "doc.pdf")
      expect(ref).to be_a(Clacky::Utils::FileProcessor::FileRef)
      expect(ref.name).to eq("doc.pdf")
      expect(File.exist?(ref.original_path)).to be true
      expect(ref.preview_path).to end_with(".preview.md")
    end

    it "propagates parse_error when parser fails" do
      allow(Clacky::Utils::ParserManager).to receive(:parse)
        .and_return({ success: false, text: nil, error: "oops", parser_path: "/some/parser.rb" })

      ref = described_class.process(body: "%PDF-1.4", filename: "bad.pdf")
      expect(ref.parse_failed?).to be true
      expect(ref.parse_error).to eq("oops")
    end
  end

  # ---------------------------------------------------------------------------
  # File type helpers
  # ---------------------------------------------------------------------------
  describe ".binary_file_path?" do
    it "returns true for PNG by extension" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end

    it "returns false for plain text files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.txt")
        File.write(f, "hello world")
        expect(described_class.binary_file_path?(f)).to be false
      end
    end

    it "returns true for files with null bytes" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.dat")
        File.binwrite(f, "abc\x00def".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end
  end

  describe ".supported_binary_file?" do
    it "returns true for images and PDF" do
      %w[test.png test.jpg test.pdf].each do |name|
        expect(described_class.supported_binary_file?(name)).to be true
      end
    end

    it "returns false for zip and docx" do
      %w[test.zip test.docx].each do |name|
        expect(described_class.supported_binary_file?(name)).to be false
      end
    end
  end

  describe ".detect_mime_type" do
    it "maps common extensions" do
      expect(described_class.detect_mime_type("a.png")).to  eq("image/png")
      expect(described_class.detect_mime_type("a.jpg")).to  eq("image/jpeg")
      expect(described_class.detect_mime_type("a.pdf")).to  eq("application/pdf")
      expect(described_class.detect_mime_type("a.bin")).to  eq("application/octet-stream")
    end
  end

  describe ".image_path_to_data_url" do
    it "converts PNG to data URL" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG\r\n\x1a\n".b)
        expect(described_class.image_path_to_data_url(f)).to start_with("data:image/png;base64,")
      end
    end

    it "raises for missing file" do
      expect { described_class.image_path_to_data_url("/no/such/file.png") }
        .to raise_error(ArgumentError, /Image file not found/)
    end

    it "raises when file exceeds MAX_IMAGE_BYTES" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "big.png")
        File.binwrite(f, "x" * (described_class::MAX_IMAGE_BYTES + 1))
        expect { described_class.image_path_to_data_url(f) }
          .to raise_error(ArgumentError, /Image too large/)
      end
    end
  end

  describe ".file_to_base64" do
    it "returns format/mime/base64 for PDF" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "%PDF-1.4")
        result = described_class.file_to_base64(f)
        expect(result[:format]).to eq("pdf")
        expect(result[:mime_type]).to eq("application/pdf")
        expect(result[:base64_data]).to be_a(String)
      end
    end

    it "raises for oversized files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "huge.pdf")
        File.binwrite(f, "x" * (described_class::MAX_FILE_BYTES + 1))
        expect { described_class.file_to_base64(f) }
          .to raise_error(ArgumentError, /File too large/)
      end
    end
  end
end
