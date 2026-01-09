# frozen_string_literal: true

require "json"

module Clacky
  module Utils
    class ArgumentsParser
      # Parse and validate tool call arguments with JSON repair capability
      def self.parse_and_validate(call, tool_registry)
        # 1. Try standard parsing
        begin
          args = JSON.parse(call[:arguments], symbolize_names: true)
          return validate_required_params(call, args, tool_registry)
        rescue JSON::ParserError => e
          # Continue to repair
        end

        # 2. Try simple repair
        repaired = repair_json(call[:arguments])

        begin
          args = JSON.parse(repaired, symbolize_names: true)
          return validate_required_params(call, args, tool_registry)
        rescue JSON::ParserError, MissingRequiredParamsError => e
          # 3. Repair failed or missing params, return helpful error
          raise_helpful_error(call, tool_registry, e)
        end
      end

      private

      # Simple JSON repair: complete brackets and quotes
      def self.repair_json(json_str)
        result = json_str.strip

        # Complete unclosed strings
        result += '"' if result.count('"').odd?

        # Complete unclosed braces
        depth = 0
        result.each_char { |c| depth += 1 if c == '{'; depth -= 1 if c == '}' }
        result += '}' * depth if depth > 0

        result
      end

      # Validate required parameters
      def self.validate_required_params(call, args, tool_registry)
        tool = tool_registry.get(call[:name])
        required = tool.parameters.dig(:required) || []

        missing = required.reject { |param|
          args.key?(param.to_sym) || args.key?(param.to_s)
        }

        if missing.any?
          raise MissingRequiredParamsError.new(call[:name], missing, args.keys)
        end

        args
      end

      # Generate error message with tool definition
      def self.raise_helpful_error(call, tool_registry, original_error)
        tool = tool_registry.get(call[:name])
        error_msg = build_error_message(call, tool, original_error)
        raise StandardError, error_msg
      end

      def self.build_error_message(call, tool, original_error)
        # Extract tool information
        required_params = tool.parameters.dig(:required) || []

        # Try to parse provided parameters from incomplete JSON
        provided_params = extract_provided_params(call[:arguments])

        # Build clear error message
        msg = []
        msg << "Failed to parse arguments for tool '#{call[:name]}'."
        msg << ""
        msg << "Error: #{original_error.message}"
        msg << ""

        if provided_params.any?
          msg << "Provided parameters: #{provided_params.join(', ')}"
        else
          msg << "No valid parameters could be extracted."
        end

        msg << "Required parameters: #{required_params.join(', ')}"
        msg << ""
        msg << "Tool definition:"
        msg << format_tool_definition(tool)
        msg << ""
        msg << "Suggestions:"
        msg << "- If the parameter value is too large (e.g., large file content), consider breaking it into smaller operations"
        msg << "- Ensure all required parameters are provided"
        msg << "- Simplify complex parameter values"

        msg.join("\n")
      end

      # Extract parameter names from incomplete JSON
      def self.extract_provided_params(json_str)
        # Simple extraction: find all "key": patterns
        json_str.scan(/"(\w+)"\s*:/).flatten.uniq
      end

      # Format tool definition (concise version)
      def self.format_tool_definition(tool)
        lines = []
        lines << "  Name: #{tool.name}"
        lines << "  Description: #{tool.description}"

        if tool.parameters[:properties]
          lines << "  Parameters:"
          tool.parameters[:properties].each do |param, spec|
            required_mark = tool.parameters[:required]&.include?(param.to_s) ? " (required)" : ""
            lines << "    - #{param}#{required_mark}: #{spec[:description]}"
          end
        end

        lines.join("\n")
      end
    end

    # Custom exception for missing required parameters
    class MissingRequiredParamsError < StandardError
      attr_reader :tool_name, :missing_params, :provided_params

      def initialize(tool_name, missing_params, provided_params)
        @tool_name = tool_name
        @missing_params = missing_params
        @provided_params = provided_params
        super("Missing required parameters: #{missing_params.join(', ')}")
      end
    end
  end
end
