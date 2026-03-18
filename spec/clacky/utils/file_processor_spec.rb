# frozen_string_literal: true

require "tmpdir"

RSpec.describe Clacky::Utils::FileProcessor do
  describe ".image_path_to_data_url" do
    it "converts PNG image to data URL" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG\r\n\x1a\n".b)
        expect(described_class.image_path_to_data_url(f)).to start_with("data:image/png;base64,")
      end
    end

    it "converts JPEG image to data URL" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.jpg")
        File.binwrite(f, "\xFF\xD8\xFF".b)
        expect(described_class.image_path_to_data_url(f)).to start_with("data:image/jpeg;base64,")
      end
    end

    it "raises ArgumentError for non-existent file" do
      expect {
        described_class.image_path_to_data_url("/nonexistent/file.png")
      }.to raise_error(ArgumentError, /Image file not found/)
    end

    it "raises ArgumentError when file exceeds MAX_IMAGE_BYTES" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "large.png")
        File.binwrite(f, "\x89PNG\r\n\x1a\n".b + "x" * (described_class::MAX_IMAGE_BYTES + 1))
        expect {
          described_class.image_path_to_data_url(f)
        }.to raise_error(ArgumentError, /Image too large/)
      end
    end

    it "accepts file within MAX_IMAGE_BYTES" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "small.png")
        File.binwrite(f, "\x89PNG\r\n\x1a\n".b)
        expect { described_class.image_path_to_data_url(f) }.not_to raise_error
      end
    end
  end

  describe ".file_to_base64" do
    it "converts PNG to base64 with metadata" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        data = "\x89PNG\r\n\x1a\n".b
        File.binwrite(f, data)
        result = described_class.file_to_base64(f)
        expect(result[:format]).to eq("png")
        expect(result[:mime_type]).to eq("image/png")
        expect(result[:base64_data]).to be_a(String)
        expect(result[:size_bytes]).to eq(data.size)
      end
    end

    it "converts PDF to base64 with metadata" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        data = "%PDF-1.4".b
        File.binwrite(f, data)
        result = described_class.file_to_base64(f)
        expect(result[:format]).to eq("pdf")
        expect(result[:mime_type]).to eq("application/pdf")
        expect(result[:base64_data]).to be_a(String)
        expect(result[:size_bytes]).to eq(data.size)
      end
    end

    it "raises ArgumentError when file exceeds MAX_FILE_BYTES" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "large.pdf")
        File.binwrite(f, "%PDF".b + "x" * (described_class::MAX_FILE_BYTES + 1))
        expect {
          described_class.file_to_base64(f)
        }.to raise_error(ArgumentError, /File too large/)
      end
    end
  end

  describe ".binary_file_path?" do
    it "returns true for PNG by extension" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "\x89PNG".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end

    it "returns true for PDF by extension" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "%PDF".b)
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

    it "returns true for files with null bytes (unknown extension)" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.dat")
        File.binwrite(f, "abc\x00def".b)
        expect(described_class.binary_file_path?(f)).to be true
      end
    end
  end

  describe ".supported_binary_file?" do
    it "returns true for image files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.png")
        File.binwrite(f, "")
        expect(described_class.supported_binary_file?(f)).to be true
      end
    end

    it "returns true for PDF files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "")
        expect(described_class.supported_binary_file?(f)).to be true
      end
    end

    it "returns false for zip files" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.zip")
        File.binwrite(f, "")
        expect(described_class.supported_binary_file?(f)).to be false
      end
    end
  end

  describe ".detect_mime_type" do
    it "returns image/png for .png" do
      expect(described_class.detect_mime_type("test.png")).to eq("image/png")
    end

    it "returns image/jpeg for .jpg" do
      expect(described_class.detect_mime_type("test.jpg")).to eq("image/jpeg")
    end

    it "returns application/pdf for .pdf" do
      expect(described_class.detect_mime_type("test.pdf")).to eq("application/pdf")
    end

    it "returns application/octet-stream for unknown extension" do
      expect(described_class.detect_mime_type("test.bin")).to eq("application/octet-stream")
    end
  end

  describe ".process" do
    it "processes a PDF and returns FileRef with original_path" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "%PDF-1.4".b)
        ref = described_class.process(body: File.binread(f), filename: "test.pdf")
        expect(ref.name).to eq("test.pdf")
        expect(ref.type).to eq(:pdf)
        expect(File.exist?(ref.original_path)).to be true
        expect(ref.preview_path).to be_nil
      end
    end

    it "to_prompt includes file name and type" do
      Dir.mktmpdir do |dir|
        f = File.join(dir, "test.pdf")
        File.binwrite(f, "%PDF-1.4".b)
        ref = described_class.process(body: File.binread(f), filename: "test.pdf")
        prompt = ref.to_prompt
        expect(prompt).to include("[File: test.pdf]")
        expect(prompt).to include("Type: pdf")
        expect(prompt).to include("Original:")
      end
    end
  end
end
