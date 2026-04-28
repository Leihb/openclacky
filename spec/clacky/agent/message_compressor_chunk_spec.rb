# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"

RSpec.describe "Compression chunk MD archiving" do
  let(:sessions_dir) { Dir.mktmpdir }
  let(:session_id) { "abc12345-0000-0000-0000-000000000000" }
  let(:created_at) { "2026-03-08T10:00:00+08:00" }

  # Minimal agent class that includes MessageCompressorHelper
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::MessageCompressorHelper

      attr_accessor :messages, :session_id, :created_at, :compressed_summaries, :compression_level

      def initialize(sessions_dir)
        @sessions_dir_override = sessions_dir
        @messages = []
        @session_id = nil
        @created_at = nil
        @compressed_summaries = []
        @compression_level = 0
      end

      def ui
        nil
      end

      def config
        double("config", enable_compression: true)
      end
    end
  end

  before do
    stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir)
  end

  after do
    FileUtils.rm_rf(sessions_dir)
  end

  subject(:agent) do
    obj = agent_class.new(sessions_dir)
    obj.session_id = session_id
    obj.created_at = created_at
    obj
  end

  let(:user_msg)      { { role: "user", content: "Tell me about compression" } }
  let(:assistant_msg) { { role: "assistant", content: "Compression reduces token usage." } }
  let(:system_msg)    { { role: "system", content: "You are a helpful assistant." } }
  let(:recent_msg)    { { role: "user", content: "And what about memory?" } }

  describe "#save_compressed_chunk" do
    it "creates a chunk MD file in the sessions directory" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      expect(path).not_to be_nil
      expect(File.exist?(path)).to be true
    end

    it "names the file with the correct pattern: datetime-shortid-chunk-n.md" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      filename = File.basename(path)
      expect(filename).to match(/\A2026-03-08-10-00-00-abc12345-chunk-1\.md\z/)
    end

    it "increments chunk index for sequential compressions" do
      original_messages = [system_msg, user_msg, assistant_msg]

      path1 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 1, compression_level: 1)
      path2 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 2, compression_level: 2)

      expect(File.basename(path1)).to include("chunk-1")
      expect(File.basename(path2)).to include("chunk-2")
    end

    it "excludes system messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("You are a helpful assistant")
    end

    it "excludes recent messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("And what about memory?")
      expect(content).to include("Tell me about compression")
    end

    it "includes user and assistant messages in readable MD format" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("## User")
      expect(content).to include("## Assistant")
      expect(content).to include("Tell me about compression")
      expect(content).to include("Compression reduces token usage.")
    end

    it "includes front matter with session metadata" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("session_id: #{session_id}")
      expect(content).to include("chunk: 1")
      expect(content).to include("compression_level: 1")
    end

    it "returns nil if session_id is not set" do
      agent.session_id = nil
      original_messages = [user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end

    it "returns nil if there are no messages to archive (only system + recent)" do
      original_messages = [system_msg, recent_msg]
      recent_messages = [recent_msg]
      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end
  end

  describe "SessionManager cleanup" do
    let(:manager) { Clacky::SessionManager.new(sessions_dir: sessions_dir) }

    # Build a minimal valid session data hash
    def session_data(session_id:, created_at:, updated_at:)
      {
        session_id: session_id,
        created_at: created_at,
        updated_at: updated_at,
        working_dir: "/tmp",
        messages: [],
        todos: [],
        time_machine: { task_parents: {}, current_task_id: 0, active_task_id: 0 },
        config: { models: {}, permission_mode: "auto_approve", enable_compression: true,
                  enable_prompt_caching: false, max_tokens: 8192, verbose: false },
        stats: { total_iterations: 0, total_cost_usd: 0.0, total_tasks: 0,
                 last_status: "ok", previous_total_tokens: 0,
                 cache_stats: {}, debug_logs: [] }
      }
    end

    # Write a chunk MD file using the same naming convention as the real code
    def write_chunk(manager, session_id, created_at, chunk_index)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      base = "#{datetime}-#{short_id}"
      chunk_path = File.join(sessions_dir, "#{base}-chunk-#{chunk_index}.md")
      File.write(chunk_path, "# Chunk #{chunk_index}\n\nSome archived content.")
      chunk_path
    end

    it "deletes associated chunk MD files when cleanup_by_count removes a session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      # Save sessions via manager so filenames are consistent
      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk_path = write_chunk(manager, old_id, old_created, 1)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      # Keep only 1 session — old one should be deleted with its chunk
      # (save already called cleanup_by_count(keep:10), so call explicitly with keep:1)
      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk_path)).to be false
    end

    it "deletes multiple chunk files for a deleted session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk1 = write_chunk(manager, old_id, old_created, 1)
      chunk2 = write_chunk(manager, old_id, old_created, 2)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk1)).to be false
      expect(File.exist?(chunk2)).to be false
    end
  end

  describe Clacky::MessageCompressor do
    describe "#rebuild_with_compression" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }
      let(:recent_msg) { { role: "user", content: "Recent message" } }

      it "injects chunk anchor into compressed summary when chunk_path is provided" do
        chunk_path = "/home/user/.clacky/sessions/2026-03-08-10-00-00-abc12345-chunk-1.md"
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: chunk_path
        )

        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:content]).to include(chunk_path)
        expect(summary_msg[:content]).to include("file_reader")
        expect(summary_msg[:chunk_path]).to eq(chunk_path)
      end

      it "does not inject anchor when chunk_path is nil" do
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: nil
        )

        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:content]).not_to include("file_reader")
        expect(summary_msg[:chunk_path]).to be_nil
      end

      it "sets compressed_summary: true on the rebuilt summary message (role: user)" do
        result = compressor.rebuild_with_compression(
          "<summary>Summary</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: nil
        )
        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:compressed_summary]).to be true
        # system_injected keeps it hidden from UI replay
        expect(summary_msg[:system_injected]).to be true
      end
    end

    describe "#parse_compressed_result" do
      let(:compressor) { described_class.new(nil) }

      it "stores topics in the returned message hash" do
        result = compressor.parse_compressed_result(
          "<topics>Rails setup, database config</topics>\n<summary>Did some work</summary>",
          chunk_path: "/tmp/chunk-1.md",
          topics: "Rails setup, database config"
        )

        msg = result.first
        expect(msg[:topics]).to eq("Rails setup, database config")
      end

      it "stores nil topics when not provided" do
        result = compressor.parse_compressed_result(
          "<summary>Did some work</summary>",
          chunk_path: "/tmp/chunk-1.md"
        )

        msg = result.first
        expect(msg[:topics]).to be_nil
      end

      it "embeds previous_chunks references in the content" do
        previous = [
          { basename: "2026-03-08-abc12345-chunk-1.md", topics: "Rails setup, database config" },
          { basename: "2026-03-08-abc12345-chunk-2.md", topics: "Deploy pipeline, bug fixes" }
        ]

        result = compressor.parse_compressed_result(
          "<topics>Refactoring</topics>\n<summary>Current work</summary>",
          chunk_path: "/tmp/chunk-3.md",
          topics: "Refactoring",
          previous_chunks: previous
        )

        msg = result.first
        content = msg[:content]

        # Should include a "Previous chunks" section (now "newest first")
        expect(content).to include("Previous chunks (newest first)")

        # Should reference each previous chunk by basename
        expect(content).to include("chunk-1.md")
        expect(content).to include("chunk-2.md")

        # Should include topics for each previous chunk
        expect(content).to include("Rails setup, database config")
        expect(content).to include("Deploy pipeline, bug fixes")

        # Should include file_reader hint
        expect(content).to include("file_reader")

        # Newest should appear first (chunk-2 before chunk-1 in string)
        pos_2 = content.index("chunk-2.md")
        pos_1 = content.index("chunk-1.md")
        expect(pos_2).to be < pos_1
      end

      it "does NOT include previous_chunks section when previous_chunks is empty" do
        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-1.md",
          previous_chunks: []
        )

        msg = result.first
        expect(msg[:content]).not_to include("Previous chunks")
      end

      it "handles previous_chunks with nil topics gracefully" do
        previous = [
          { basename: "chunk-1.md", topics: nil },
          { basename: "chunk-2.md", topics: "Some work" }
        ]

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-3.md",
          previous_chunks: previous
        )

        content = result.first[:content]
        # chunk-1.md should appear without " — " suffix
        expect(content).to include("chunk-1.md")
        # chunk-2.md should include its topics
        expect(content).to include("Some work")
      end

      it "caps at 10 visible chunks and shows newest first (reverse order)" do
        # Simulate 12 previous chunks
        previous = (1..12).map do |i|
          { basename: "chunk-#{i}.md", topics: "Topic #{i}" }
        end

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-13.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # Should show only the 10 newest: chunk-12 through chunk-3 (reverse order)
        expect(content).to include("chunk-12.md")
        expect(content).to include("chunk-3.md")

        # Should NOT show the 2 oldest in the numbered list
        # (they appear only in the "older chunks back to" summary line)
        # chunk-12 through chunk-3 = 10 visible entries
        (3..12).each do |i|
          expect(content).to include("chunk-#{i}.md")
        end

        # Should mention older chunks count and reference the oldest
        expect(content).to include("and 2 older chunks back to")
        expect(content).to include("`chunk-1.md`")

        # chunk-2.md should NOT appear at all (not in visible list, not in older note)
        expect(content).not_to include("chunk-2.md")

        # Should mention older chunks count
        expect(content).to include("and 2 older chunks back to")

        # Newest should appear first (chunk-12 before chunk-11 in string)
        pos_12 = content.index("chunk-12.md")
        pos_11 = content.index("chunk-11.md")
        expect(pos_12).to be < pos_11
      end

      it "shows all chunks without cap note when total <= 10" do
        previous = (1..5).map do |i|
          { basename: "chunk-#{i}.md", topics: "Topic #{i}" }
        end

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-6.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # All 5 should be visible
        expect(content).to include("chunk-1.md")
        expect(content).to include("chunk-5.md")

        # No "older chunks" note
        expect(content).not_to include("older chunks back to")
      end

      it "previous_chunks section appears between summary and current chunk anchor" do
        previous = [{ basename: "chunk-1.md", topics: "Setup" }]

        result = compressor.parse_compressed_result(
          "<summary>Work done</summary>",
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # The previous chunks section should come after the summary text
        # and before the current chunk anchor
        summary_pos = content.index("Work done")
        prev_chunks_pos = content.index("Previous chunks")
        current_anchor_pos = content.index("Current chunk archived at")

        expect(summary_pos).to be < prev_chunks_pos
        expect(prev_chunks_pos).to be < current_anchor_pos
      end
    end

    describe "#rebuild_with_compression with topics and previous_chunks" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }
      let(:recent_msg) { { role: "user", content: "Recent" } }

      it "passes topics through to the compressed summary message" do
        result = compressor.rebuild_with_compression(
          "<topics>Rails, DB</topics>\n<summary>Work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-1.md",
          topics: "Rails, DB"
        )

        summary = result.find { |m| m[:compressed_summary] }
        expect(summary[:topics]).to eq("Rails, DB")
      end

      it "embeds previous_chunks in the rebuilt summary content" do
        previous = [{ basename: "chunk-1.md", topics: "Initial setup" }]

        result = compressor.rebuild_with_compression(
          "<summary>Second batch of work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        summary = result.find { |m| m[:compressed_summary] }
        expect(summary[:content]).to include("Previous chunks")
        expect(summary[:content]).to include("chunk-1.md")
        expect(summary[:content]).to include("Initial setup")
      end

      it "history role sequence still valid with previous_chunks (summary as user anchor)" do
        previous = [{ basename: "chunk-1.md", topics: "Setup" }]

        result = compressor.rebuild_with_compression(
          "<summary>Recent work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        roles = result.map { |m| m[:role].to_s }
        expect(roles[0]).to eq("system")
        expect(roles[1]).to eq("user")  # summary still acts as user anchor
        expect(roles[1..]).not_to include("system")  # system only at position 0
      end
    end

    # Regression: a previous implementation placed the compressed summary as
    # `role: "assistant"` right after the `system` message. If the very next
    # kept message was also an assistant (e.g. because the last user turn had
    # already been archived into the chunk), the rebuilt history sent to the
    # API contained two consecutive assistant messages — and worse, an
    # `assistant + tool_calls` chain with no preceding user anchor. OpenAI-
    # compatible providers reject this with 400 "tool_use ids found without
    # tool_result blocks" / "messages must alternate".
    #
    # The summary must be `role: "user"` so it acts as the anchor for any
    # orphaned assistant/tool_result messages that follow it.
    describe "#rebuild_with_compression history structure (regression)" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }

      # Helper: flatten rebuilt history into a role sequence for assertions
      def role_sequence(messages)
        messages.map { |m| m[:role].to_s }
      end

      it "never produces two consecutive assistant messages after compression" do
        # Scenario: the chunk swallowed the trailing user turn; recent_messages
        # starts with an assistant message carrying tool_calls.
        recent = [
          { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "shell", arguments: {} }] },
          { role: "tool",      content: "output", tool_call_id: "t1" },
          { role: "assistant", content: "Done." }
        ]

        result = compressor.rebuild_with_compression(
          "<summary>Earlier work summary</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: "/tmp/fake-chunk-1.md"
        )

        roles = role_sequence(result)
        # Walk the sequence and assert no two adjacent assistants
        roles.each_cons(2) do |a, b|
          expect([a, b]).not_to eq(%w[assistant assistant]),
            "found consecutive assistants in rebuilt history: #{roles.inspect}"
        end
      end

      it "places a user message before any assistant-with-tool_calls chain" do
        # This is the exact shape that triggered the production 400 error:
        # system → [summary] → assistant(tool_calls) → tool → assistant
        recent = [
          { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "shell", arguments: {} }] },
          { role: "tool",      content: "ok", tool_call_id: "t1" }
        ]

        result = compressor.rebuild_with_compression(
          "<summary>Prior conversation</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: "/tmp/fake-chunk-1.md"
        )

        # Find the first assistant message that carries tool_calls
        first_tool_call_idx = result.index { |m| m[:role] == "assistant" && !Array(m[:tool_calls]).empty? }
        expect(first_tool_call_idx).not_to be_nil

        # Every assistant+tool_calls must have at least one user message somewhere before it
        preceding = result[0...first_tool_call_idx]
        expect(preceding.any? { |m| m[:role] == "user" }).to be(true),
          "no user anchor before assistant(tool_calls); got roles: #{role_sequence(result).inspect}"
      end

      it "rebuilt history starts with system then user (summary acts as user anchor)" do
        recent = [{ role: "assistant", content: "hello" }]

        result = compressor.rebuild_with_compression(
          "<summary>s</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: nil
        )

        expect(result[0][:role]).to eq("system")
        expect(result[1][:role]).to eq("user")
        expect(result[1][:compressed_summary]).to be true
      end
    end
  end

  # ── chunk_index derivation from history ──────────────────────────────────────
  #
  # chunk_index must be derived by counting compressed_summary messages already
  # in original_messages — NOT from @compressed_summaries.size, which resets to
  # 0 on every process restart and would cause index collisions that overwrite
  # existing chunk files, creating circular chunk references.
  describe "chunk_index derivation from compressed_summary messages in history" do
    def count_index(messages)
      messages.count { |m| m[:compressed_summary] } + 1
    end

    it "first compression produces chunk-1 when history has no prior summaries" do
      messages = [
        { role: "system",    content: "sys" },
        { role: "user",      content: "hi" },
        { role: "assistant", content: "hello" }
      ]
      expect(count_index(messages)).to eq(1)
    end

    it "second compression produces chunk-2 when one summary already in history" do
      messages = [
        { role: "system",    content: "sys" },
        { role: "assistant", content: "Summary of chunk 1", compressed_summary: true, chunk_path: "xxx-chunk-1.md" },
        { role: "user",      content: "next question" }
      ]
      expect(count_index(messages)).to eq(2)
    end

    it "third compression produces chunk-3 with two prior summaries" do
      messages = [
        { role: "system",    content: "sys" },
        { role: "assistant", content: "s1", compressed_summary: true, chunk_path: "xxx-chunk-1.md" },
        { role: "assistant", content: "s2", compressed_summary: true, chunk_path: "xxx-chunk-2.md" },
        { role: "user",      content: "q" }
      ]
      expect(count_index(messages)).to eq(3)
    end

    it "after restart with 9 existing chunks produces chunk-10 (no reset)" do
      messages = 9.times.map { |i|
        { role: "assistant", content: "s#{i+1}", compressed_summary: true, chunk_path: "xxx-chunk-#{i+1}.md" }
      } + [{ role: "user", content: "new" }]
      expect(count_index(messages)).to eq(10)
    end

    it "ignores non-compressed assistant messages in the count" do
      messages = [
        { role: "assistant", content: "normal reply" },                                          # no compressed_summary
        { role: "assistant", content: "s1", compressed_summary: true, chunk_path: "c-1.md" },
        { role: "assistant", content: "s2", compressed_summary: false, chunk_path: "c-x.md" },  # explicitly false
        { role: "user",      content: "q" }
      ]
      expect(count_index(messages)).to eq(2)
    end
  end
end
