# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    MAX_RETRIES = 10
    RETRY_DELAY = 5 # seconds

    def initialize(api_key, base_url:, model: nil, anthropic_format: false)
      @api_key = api_key
      @base_url = base_url
      @model = model
      @use_anthropic_format = anthropic_format
    end

    # Returns true when the client is talking directly to the Anthropic API
    # (determined at construction time via the anthropic_format flag).
    def anthropic_format?(model = nil)
      @use_anthropic_format
    end

    # ── Connection test ───────────────────────────────────────────────────────

    # Test API connection by sending a minimal request.
    # Returns { success: true } or { success: false, error: "..." }.
    def test_connection(model:)
      minimal_body = { model: model, max_tokens: 16,
                       messages: [{ role: "user", content: "hi" }] }.to_json

      response = if anthropic_format?
                   anthropic_connection.post("v1/messages") { |r| r.body = minimal_body }
                 else
                   openai_connection.post("chat/completions") { |r| r.body = minimal_body }
                 end
      handle_test_response(response)
    rescue Faraday::Error => e
      { success: false, error: "Connection error: #{e.message}" }
    rescue => e
      { success: false, error: e.message }
    end

    # ── Simple (non-agent) helpers ────────────────────────────────────────────

    # Send a single string message and return the reply text.
    def send_message(content, model:, max_tokens:)
      messages = [{ role: "user", content: content }]
      send_messages(messages, model: model, max_tokens: max_tokens)
    end

    # Send a messages array and return the reply text.
    def send_messages(messages, model:, max_tokens:)
      if anthropic_format?
        body     = MessageFormat::Anthropic.build_request_body(messages, model, [], max_tokens, false)
        response = anthropic_connection.post("v1/messages") { |r| r.body = body.to_json }
        parse_simple_anthropic_response(response)
      else
        body     = { model: model, max_tokens: max_tokens, messages: messages }
        response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }
        parse_simple_openai_response(response)
      end
    end

    # ── Agent main path ───────────────────────────────────────────────────────

    # Send messages with tool-calling support.
    # Returns canonical response hash: { content:, tool_calls:, finish_reason:, usage: }
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, enable_caching: false)
      caching_enabled = enable_caching && supports_prompt_caching?(model)
      cloned = deep_clone(messages)

      if anthropic_format?
        send_anthropic_request(cloned, model, tools, max_tokens, caching_enabled)
      else
        send_openai_request(cloned, model, tools, max_tokens, caching_enabled)
      end
    end

    # Format tool results into canonical messages ready to append to @messages.
    # Always returns canonical format (role: "tool") regardless of API type —
    # conversion to API-native happens inside each send_*_request.
    def format_tool_results(response, tool_results, model:)
      return [] if tool_results.empty?

      if anthropic_format?
        MessageFormat::Anthropic.format_tool_results(response, tool_results)
      else
        MessageFormat::OpenAI.format_tool_results(response, tool_results)
      end
    end

    # ── Prompt-caching support ────────────────────────────────────────────────

    # Returns true for Claude 3.5+ models that support prompt caching.
    def supports_prompt_caching?(model)
      model_str = model.to_s.downcase
      return false unless model_str.include?("claude")

      model_str.match?(/claude(?:-3[-.]?[5-9]|-[4-9]|-sonnet-[34])/)
    end

    private

    # ── Anthropic request / response ──────────────────────────────────────────

    def send_anthropic_request(messages, model, tools, max_tokens, caching_enabled)
      # Apply cache_control to the message that marks the cache breakpoint
      messages = apply_message_caching(messages) if caching_enabled

      body     = MessageFormat::Anthropic.build_request_body(messages, model, tools, max_tokens, caching_enabled)
      response = anthropic_connection.post("v1/messages") { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      MessageFormat::Anthropic.parse_response(JSON.parse(response.body))
    end

    def parse_simple_anthropic_response(response)
      raise_error(response) unless response.status == 200
      data = JSON.parse(response.body)
      (data["content"] || []).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("")
    end

    # ── OpenAI request / response ─────────────────────────────────────────────

    def send_openai_request(messages, model, tools, max_tokens, caching_enabled)
      # Apply cache_control markers to messages when caching is enabled.
      # OpenRouter proxies Claude with the same cache_control field convention as Anthropic direct.
      messages = apply_message_caching(messages) if caching_enabled

      body     = MessageFormat::OpenAI.build_request_body(messages, model, tools, max_tokens, caching_enabled)
      response = openai_connection.post("chat/completions") { |r| r.body = body.to_json }

      raise_error(response) unless response.status == 200
      MessageFormat::OpenAI.parse_response(JSON.parse(response.body))
    end

    def parse_simple_openai_response(response)
      raise_error(response) unless response.status == 200
      JSON.parse(response.body)["choices"].first["message"]["content"]
    end

    # ── Prompt caching helpers ────────────────────────────────────────────────

    # Add cache_control marker to the appropriate message in the array.
    #
    # Strategy: mark the SECOND-TO-LAST non-injected assistant message.
    #
    # Rationale: Anthropic prompt caching is prefix-based. If we mark the last
    # message (typically the latest user turn or tool_result), the cached prefix
    # changes every request because tool results and user inputs vary each turn.
    # This causes alternating miss/hit patterns observed in production.
    #
    # By placing the breakpoint on the most recent ASSISTANT message that precedes
    # the current user turn, we cache everything up to (and including) the last LLM
    # reply — a stable prefix. The new user turn + any tool results live AFTER the
    # breakpoint and are not cached (they change every request anyway).
    #
    # Special cases:
    #   - Compression instruction as last message: skip it, find the assistant before it.
    #   - Fewer than 2 messages: fall back to marking the last message.
    def apply_message_caching(messages)
      return messages if messages.empty?

      # Walk backwards to find the last assistant message that is not system_injected.
      # That is the stable "end of history" to anchor the cache breakpoint on.
      cache_index = nil
      messages.each_with_index.reverse_each do |msg, idx|
        next if msg[:system_injected]
        if msg[:role] == "assistant"
          cache_index = idx
          break
        end
      end

      # Fallback: if no assistant message found, mark the last message
      cache_index ||= messages.length - 1

      messages.map.with_index do |msg, idx|
        idx == cache_index ? add_cache_control_to_message(msg) : msg
      end
    end

    # Wrap or extend the message's content with a cache_control marker.
    def add_cache_control_to_message(msg)
      content = msg[:content]

      content_array = case content
                      when String
                        [{ type: "text", text: content, cache_control: { type: "ephemeral" } }]
                      when Array
                        content.map.with_index do |block, idx|
                          idx == content.length - 1 ? block.merge(cache_control: { type: "ephemeral" }) : block
                        end
                      else
                        return msg
                      end

      msg.merge(content: content_array)
    end

    # Only true for the compression-instruction user message inserted by MessageCompressor.
    # Skill shim messages (also system_injected: true) must NOT be treated as compression
    # instructions — doing so shifts the cache breakpoint into the volatile skill content
    # block, causing a full cache miss on every slash command turn.
    def is_compression_instruction?(message)
      return false unless message.is_a?(Hash)
      return false unless message[:system_injected] == true
      return false unless message[:role] == "user"

      content = message[:content].to_s
      content.include?("CRITICAL: TASK CHANGE - MEMORY COMPRESSION MODE") ||
        content.include?("MEMORY COMPRESSION MODE")
    end

    # ── HTTP connections ──────────────────────────────────────────────────────

    def openai_connection
      @openai_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]  = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout      = 120
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    def anthropic_connection
      @anthropic_connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"]   = "application/json"
        conn.headers["x-api-key"]      = @api_key
        conn.headers["anthropic-version"] = "2023-06-01"
        conn.headers["anthropic-dangerous-direct-browser-access"] = "true"
        conn.options.timeout      = 120
        conn.options.open_timeout = 10
        conn.ssl.verify           = false
        conn.adapter Faraday.default_adapter
      end
    end

    # ── Error handling ────────────────────────────────────────────────────────

    def handle_test_response(response)
      return { success: true } if response.status == 200

      error_body = JSON.parse(response.body) rescue nil
      { success: false, error: extract_error_message(error_body, response.body) }
    end

    def raise_error(response)
      error_body    = JSON.parse(response.body) rescue nil
      error_message = extract_error_message(error_body, response.body)

      case response.status
      when 400
        hint = error_message.downcase.match?(/unavailable|quota/) ? " (possibly out of credits)" : ""
        raise AgentError, "API request failed (400): #{error_message}#{hint}"
      when 401 then raise AgentError, "Invalid API key"
      when 403 then raise AgentError, "Access denied: #{error_message}"
      when 404 then raise AgentError, "API endpoint not found: #{error_message}"
      when 429 then raise AgentError, "Rate limit exceeded"
      when 500..599 then raise AgentError, "Server error (#{response.status}): #{error_message}"
      else raise AgentError, "Unexpected error (#{response.status}): #{error_message}"
      end
    end

    def extract_error_message(error_body, raw_body)
      if raw_body.is_a?(String) && raw_body.strip.start_with?("<!DOCTYPE", "<html")
        return "Invalid API endpoint or server error (received HTML instead of JSON)"
      end

      return raw_body unless error_body.is_a?(Hash)

      error_body["upstreamMessage"]&.then { |m| return m unless m.empty? }
      error_body.dig("error", "message")&.then { |m| return m }
      error_body["message"]&.then             { |m| return m }
      error_body["error"].is_a?(String) ? error_body["error"] : (raw_body.to_s[0..200] + (raw_body.to_s.length > 200 ? "..." : ""))
    end

    # ── Utilities ─────────────────────────────────────────────────────────────

    def deep_clone(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
      when Array then obj.map { |item| deep_clone(item) }
      else obj
      end
    end
  end
end
