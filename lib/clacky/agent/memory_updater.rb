# frozen_string_literal: true

module Clacky
  class Agent
    # Long-term memory update functionality
    # Triggered at the end of a session to persist important knowledge.
    #
    # Pattern: Same as message compression — insert an instruction message
    # into the conversation, let LLM respond by calling the write tool
    # to update ~/.clacky/memories/*.md files directly.
    #
    # The LLM decides:
    #   - Which topics were discussed
    #   - Which memory files to update or create
    #   - How to merge new info with existing content
    #   - What to drop to stay within the per-file token limit
    module MemoryUpdater
      # Minimum iterations before we consider updating memory
      MEMORY_UPDATE_MIN_ITERATIONS = 5

      MEMORIES_DIR = File.expand_path("~/.clacky/memories")

      MEMORY_UPDATE_PROMPT = <<~PROMPT.freeze
        ═══════════════════════════════════════════════════════════════
        MEMORY UPDATE MODE
        ═══════════════════════════════════════════════════════════════
        The conversation above has ended. You are now in MEMORY UPDATE MODE.

        Your task: Persist important knowledge from this session into long-term memory.

        ## Memory Location
        All memory files live in `~/.clacky/memories/`. Each file covers one topic and has YAML frontmatter:

        ```
        ---
        topic: <topic name>
        description: <one-line description>
        updated_at: <YYYY-MM-DD>
        ---

        <content in concise Markdown>
        ```

        ## What to memorize
        From this conversation, identify knowledge worth persisting:
        - Important decisions made (technical, product, process)
        - New concepts or context introduced by the user
        - Corrections to previous understanding
        - User preferences or working style observations

        Do NOT memorize: task details, code snippets, debugging steps, or anything ephemeral.

        ## Steps

        1. List existing memory files: use `file_reader` on `~/.clacky/memories/`
        2. For each relevant topic from this session:
           a. If a matching file exists → read it, then write an updated version (merge new + old, drop stale)
           b. If no matching file → create a new one
        3. Use the `write` tool to save each file

        ## Hard constraints (CRITICAL)
        - Each file MUST stay under 4000 characters of content (after the frontmatter)
        - If merging would exceed this limit, remove the least important information
        - Write concise, factual Markdown — no fluff
        - Update `updated_at` to today's date: #{Time.now.strftime("%Y-%m-%d")}
        - Only write files for topics that genuinely appeared in this conversation
        - If nothing worth memorizing occurred, do nothing and respond: "No memory updates needed."

        Begin now.
      PROMPT

      # Check if memory update should be triggered for this session
      # @return [Boolean]
      def should_update_memory?
        return false unless memory_update_enabled?

        # Only update if conversation had meaningful depth
        task_iterations = @iterations - (@task_start_iterations || 0)
        task_iterations >= MEMORY_UPDATE_MIN_ITERATIONS
      end

      # Trigger memory update at end of session
      # Inserts a memory update instruction into the conversation and runs one LLM turn
      def trigger_memory_update
        return unless should_update_memory?

        @ui&.show_info("Updating long-term memory...")

        # Insert memory update instruction as a user message
        @messages << {
          role: "user",
          content: MEMORY_UPDATE_PROMPT,
          system_injected: true,
          memory_update: true
        }

        begin
          # Run one LLM turn — it will call write tool to update files
          response = think
          return if response.nil?

          # If LLM calls tools (write), execute them
          until response[:tool_calls].nil? || response[:tool_calls].empty? || response[:finish_reason] == "stop"
            act(response[:tool_calls])
            observe(response, [])
            response = think
            break if response.nil?
          end

          @ui&.show_info("Memory updated.")
        rescue StandardError => e
          @ui&.log("Memory update failed: #{e.message}", level: :warn)
        ensure
          # Remove the memory update instruction from conversation history
          # so it doesn't pollute future context
          @messages.reject! { |m| m[:memory_update] }
        end
      end

      private def memory_update_enabled?
        # Check config flag; default to true if not set
        return true unless @config.respond_to?(:memory_update_enabled)

        @config.memory_update_enabled != false
      end
    end
  end
end
