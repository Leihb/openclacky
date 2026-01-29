# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # MessageComponent renders user and assistant messages
      class MessageComponent < BaseComponent
        # Render a message
        # @param data [Hash] Message data
        #   - :role [String] "user" or "assistant"
        #   - :content [String] Message content
        #   - :timestamp [Time, nil] Optional timestamp
        #   - :images [Array<String>] Optional image paths (for user messages)
        #   - :prefix_newline [Boolean] Whether to add newline before message (for system messages)
        # @return [String] Rendered message
        def render(data)
          role = data[:role]
          content = data[:content]
          timestamp = data[:timestamp]
          images = data[:images] || []
          prefix_newline = data.fetch(:prefix_newline, true)
          
          case role
          when "user"
            render_user_message(content, timestamp, images)
          when "assistant"
            render_assistant_message(content, timestamp)
          else
            render_system_message(content, timestamp, prefix_newline)
          end
        end

        private

        # Render user message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @param images [Array<String>] Optional image paths
        # @return [String] Rendered message
        def render_user_message(content, timestamp = nil, images = [])
          symbol = format_symbol(:user)
          text = format_text(content, :user)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end

        # Render assistant message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @return [String] Rendered message
        def render_assistant_message(content, timestamp = nil)
          return "" if content.nil? || content.empty?

          symbol = format_symbol(:assistant)
          text = format_text(content, :assistant)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          "\n#{symbol} #{text} #{time_str}".rstrip
        end

        # Render system message
        # @param content [String] Message content
        # @param timestamp [Time, nil] Optional timestamp
        # @param prefix_newline [Boolean] Whether to add newline before message
        # @return [String] Rendered message
        private def render_system_message(content, timestamp = nil, prefix_newline = true)
          symbol = format_symbol(:info)
          text = format_text(content, :info)
          time_str = timestamp ? @pastel.dim("[#{format_timestamp(timestamp)}]") : ""

          prefix = prefix_newline ? "\n" : ""
          "#{prefix}#{symbol} #{text} #{time_str}".rstrip
        end
      end
    end
  end
end
