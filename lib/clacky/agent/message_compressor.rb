# frozen_string_literal: true

module Clacky
  # Message compressor using Insert-then-Compress strategy
  #
  # New Strategy: Instead of creating a separate API call for compression,
  # we insert a compression instruction into the current conversation flow.
  # This allows us to reuse the existing cache (system prompt + tools) and
  # only pay for processing the new compression instruction.
  #
  # Flow:
  # 1. Agent detects compression threshold is reached
  # 2. Compressor builds a compression instruction message
  # 3. Agent inserts this message and calls LLM (with cache reuse!)
  # 4. LLM returns compressed summary
  # 5. Compressor rebuilds message list: system + summary + recent messages
  # 6. Agent continues with new message list (cache will rebuild from here)
  #
  # Benefits:
  # - Compression call reuses existing cache (huge token savings)
  # - Only one cache rebuild after compression (vs two with old approach)
  #
  class MessageCompressor
    COMPRESSION_PROMPT = <<~PROMPT.freeze
      ═══════════════════════════════════════════════════════════════
      CRITICAL: TASK CHANGE - MEMORY COMPRESSION MODE
      ═══════════════════════════════════════════════════════════════
      The conversation above has ENDED. You are now in MEMORY COMPRESSION MODE.

      CRITICAL INSTRUCTIONS - READ CAREFULLY:

      1. This is NOT a continuation of the conversation
      2. DO NOT respond to any requests in the conversation above
      3. DO NOT call ANY tools or functions
      4. DO NOT use tool_calls in your response
      5. Your response MUST be PURE TEXT ONLY

      YOUR ONLY TASK: Create a comprehensive summary of the conversation above.

      REQUIRED RESPONSE FORMAT:
      First output a <topics> line listing 3-6 key topic phrases (comma-separated, concise).
      Then output the full summary wrapped in <summary> tags.

      Example format:
      <topics>Rails setup, database config, deploy pipeline, Tailwind CSS</topics>
      <summary>
      ...full summary text...
      </summary>

      Focus on:
      - User's explicit requests and intents
      - Key technical concepts and code changes
      - Files examined and modified
      - Errors encountered and fixes applied
      - Current work status and pending tasks

      Begin your response NOW. Remember: PURE TEXT only, starting with <topics> then <summary>.
    PROMPT

    def initialize(client, model: nil)
      @client = client
      @model = model
    end

    # Generate compression instruction message to be inserted into conversation
    # This enables cache reuse by using the same API call with tools
    # 
    # SIMPLIFIED APPROACH:
    # - Don't duplicate conversation history in the compression message
    # - LLM can already see all messages, just ask it to compress
    # - Keep the instruction small for better cache efficiency
    #
    # @param messages [Array<Hash>] Original conversation messages
    # @param recent_messages [Array<Hash>] Recent messages to keep uncompressed (optional)
    # @return [Hash] Compression instruction message to insert, or nil if nothing to compress
    def build_compression_message(messages, recent_messages: [])
      # Get messages to compress (exclude system message and recent messages)
      messages_to_compress = messages.reject { |m| m[:role] == "system" || recent_messages.include?(m) }

      # If nothing to compress, return nil
      return nil if messages_to_compress.empty?

      # Simple compression instruction - LLM can see the history already
      { 
        role: "user", 
        content: COMPRESSION_PROMPT,
        system_injected: true
      }
    end

    # Parse LLM response and rebuild message list with compression
    # @param compressed_content [String] The compressed summary from LLM
    # @param original_messages [Array<Hash>] Original messages before compression
    # @param recent_messages [Array<Hash>] Recent messages to preserve
    # @param chunk_path [String, nil] Path to the archived chunk MD file (if saved)
    # @return [Array<Hash>] Rebuilt message list: system + compressed + recent
    def rebuild_with_compression(compressed_content, original_messages:, recent_messages:, chunk_path: nil)
      # Find and preserve system message
      system_msg = original_messages.find { |m| m[:role] == "system" }

      # Parse the compressed result
      parsed_messages = parse_compressed_result(compressed_content, chunk_path: chunk_path)

      # If parsing fails or returns empty, raise error
      if parsed_messages.nil? || parsed_messages.empty?
        raise "LLM compression failed: unable to parse compressed messages"
      end

      # Return system message + compressed messages + recent messages.
      # Strip any system messages from recent_messages as a safety net —
      # get_recent_messages_with_tool_pairs already excludes them, but this
      # guard ensures we never end up with duplicate system prompts even if
      # the caller passes an unfiltered list.
      safe_recent = recent_messages.reject { |m| m[:role] == "system" }
      [system_msg, *parsed_messages, *safe_recent].compact
    end


    # Parse topics tag from compressed content.
    # Returns the topics string if found, nil otherwise.
    # e.g. "<topics>Rails setup, database config</topics>" → "Rails setup, database config"
    def parse_topics(content)
      m = content.match(/<topics>(.*?)<\/topics>/m)
      m ? m[1].strip : nil
    end

    def parse_compressed_result(result, chunk_path: nil)
      # Return the compressed result as a single user message (role: "user").
      #
      # Why role:"user" instead of "assistant":
      #   When all original user messages get archived into the chunk during compression
      #   (e.g. a long single-turn `/slash` task), the rebuilt history can end up as
      #   `system → assistant(summary) → assistant(tool_calls) → tool → …` with NO user
      #   message anywhere. Strict providers (notably DeepSeek V4 thinking mode) reject
      #   this as a malformed turn structure with a misleading
      #   "reasoning_content must be passed back" 400 error.
      #
      # Marking it as a user message gives the conversation a valid turn boundary.
      # `system_injected: true` ensures the UI's replay_history still hides it from
      # the chat panel (the real-user filter excludes system_injected messages), while
      # INTERNAL_FIELDS in MessageHistory strips the marker before the API payload is
      # built — so DeepSeek/OpenAI/Anthropic only see a plain `{role:"user", content:…}`.
      #
      # The `compressed_summary: true` flag is preserved so that replay_history still
      # routes this message through the chunk-expansion path (which keys off that flag,
      # not the role).
      content = result.to_s.strip

      if content.empty?
        []
      else
        # Strip out the <topics> block — it's metadata for the chunk file, not for AI context
        content_without_topics = content.gsub(/<topics>.*?<\/topics>\n*/m, "").strip

        # Inject chunk anchor so AI knows where to find original conversation
        if chunk_path
          anchor = "\n\n---\n📁 **Original conversation archived at:** `#{chunk_path}`\n" \
                   "_Use `file_reader` tool to recall details from this chunk._"
          content_without_topics = content_without_topics + anchor
        end

        # Prefix lets the model recognise this is injected context, not a user utterance.
        framed_content = "[Compressed conversation summary — previous turns archived]\n\n" \
                         "#{content_without_topics}"

        [{
          role: "user",
          content: framed_content,
          compressed_summary: true,
          chunk_path: chunk_path,
          system_injected: true
        }]
      end
    end
  end
end
