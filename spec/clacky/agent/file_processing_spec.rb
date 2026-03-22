# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Agent file processing" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    Clacky::AgentConfig.new(model: "gpt-4o", permission_mode: :auto_approve)
  end
  let(:agent) do
    Clacky::Agent.new(client, config,
      working_dir: Dir.pwd, ui: nil,
      profile: "coding",
      session_id: Clacky::SessionManager.generate_id)
  end

  # Stub the LLM so agent.run returns after one iteration
  def stub_llm_reply(text)
    allow(client).to receive(:send_messages_with_tools)
      .and_return(mock_api_response(content: text))
    allow(client).to receive(:format_tool_results).and_return([])
  end

  describe "disk file parsing is called during agent.run" do
    it "calls FileProcessor.process_path for each non-image disk file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "report.pdf")
        File.binwrite(path, "%PDF-1.4")

        ref = Clacky::Utils::FileProcessor::FileRef.new(
          name: "report.pdf", type: :pdf,
          original_path: path, preview_path: "#{path}.preview.md"
        )
        allow(Clacky::Utils::FileProcessor).to receive(:process_path)
          .with(path, name: "report.pdf")
          .and_return(ref)

        stub_llm_reply("Done")
        agent.run("analyze this", files: [{ name: "report.pdf", path: path }])

        expect(Clacky::Utils::FileProcessor).to have_received(:process_path)
          .with(path, name: "report.pdf")
      end
    end

    it "does NOT call process_path for image files (they go via vision path)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "photo.png")
        File.binwrite(path, "\x89PNG\r\n\x1a\n")

        expect(Clacky::Utils::FileProcessor).not_to receive(:process_path)

        stub_llm_reply("Nice photo")
        # Images are identified by mime_type, not path
        agent.run("look at this", files: [{ name: "photo.png", path: path, mime_type: "image/png" }])
      end
    end
  end

  describe "file_prompt injected into history" do
    it "includes preview path when parse succeeds" do
      Dir.mktmpdir do |dir|
        path     = File.join(dir, "doc.docx")
        preview  = "#{path}.preview.md"
        File.binwrite(path, "bytes")
        File.write(preview, "# Document content")

        ref = Clacky::Utils::FileProcessor::FileRef.new(
          name: "doc.docx", type: :document,
          original_path: path, preview_path: preview
        )
        allow(Clacky::Utils::FileProcessor).to receive(:process_path).and_return(ref)

        stub_llm_reply("Done")
        agent.run("read this doc", files: [{ name: "doc.docx", path: path }])

        injected = agent.history.to_a.select { |e| e[:system_injected] }.last
        expect(injected[:content]).to include("Preview (Markdown): #{preview}")
        expect(injected[:content]).to include("[File: doc.docx]")
      end
    end

    it "includes parse_error repair hint when parse fails" do
      Dir.mktmpdir do |dir|
        path        = File.join(dir, "bad.pdf")
        parser_path = "/home/.clacky/parsers/pdf_parser.rb"
        File.binwrite(path, "not a pdf")

        ref = Clacky::Utils::FileProcessor::FileRef.new(
          name: "bad.pdf", type: :pdf,
          original_path: path,
          parse_error: "pdftotext: command not found",
          parser_path: parser_path
        )
        allow(Clacky::Utils::FileProcessor).to receive(:process_path).and_return(ref)

        stub_llm_reply("I'll fix the parser")
        agent.run("read this pdf", files: [{ name: "bad.pdf", path: path }])

        injected = agent.history.to_a.select { |e| e[:system_injected] }.last
        expect(injected[:content]).to include("Parse failed: pdftotext: command not found")
        expect(injected[:content]).to include("Action required: fix the parser at #{parser_path}")
        expect(injected[:content]).to include("ruby #{parser_path} #{path}")
      end
    end

    it "skips file_prompt injection when no files given" do
      stub_llm_reply("Hello")
      agent.run("hello", files: [])

        # Exclude session_context injections — only check for file-related ones
        injected = agent.history.to_a.select { |e| e[:system_injected] && !e[:session_context] }
        expect(injected).to be_empty    end
  end
end
