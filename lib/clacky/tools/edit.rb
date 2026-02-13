# frozen_string_literal: true

module Clacky
  module Tools
    class Edit < Base
      self.tool_name = "edit"
      self.tool_description = "Make precise edits to existing files by replacing old text with new text. " \
                              "The old_string must match exactly (including whitespace and indentation)."
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "The path of the file to edit (absolute or relative)"
          },
          old_string: {
            type: "string",
            description: "The exact string to find and replace (must match exactly including whitespace)"
          },
          new_string: {
            type: "string",
            description: "The new string to replace the old string with"
          },
          replace_all: {
            type: "boolean",
            description: "If true, replace all occurrences. If false (default), replace only the first occurrence",
            default: false
          }
        },
        required: %w[path old_string new_string]
      }

      def execute(path:, old_string:, new_string:, replace_all: false)
        # Validate path
        unless File.exist?(path)
          return { error: "File not found: #{path}" }
        end

        unless File.file?(path)
          return { error: "Path is not a file: #{path}" }
        end

        begin
          # Read current content
          content = File.read(path)
          original_content = content.dup

          # Try exact match first
          if content.include?(old_string)
            actual_old_string = old_string
            occurrences = content.scan(old_string).length
          else
            # Try smart whitespace normalization
            match_result = try_smart_match(content, old_string)
            
            if match_result
              actual_old_string = match_result[:matched_string]
              occurrences = match_result[:occurrences]
            else
              # Provide helpful error with context
              return build_helpful_error(content, old_string, path)
            end
          end

          # If not replace_all and multiple occurrences, warn about ambiguity
          if !replace_all && occurrences > 1
            return {
              error: "String appears #{occurrences} times in the file. Use replace_all: true to replace all occurrences, " \
                     "or provide a more specific string that appears only once."
            }
          end

          # Perform replacement
          if replace_all
            content = content.gsub(actual_old_string, new_string)
          else
            content = content.sub(actual_old_string, new_string)
          end

          # Write modified content
          File.write(path, content)

          {
            path: File.expand_path(path),
            replacements: replace_all ? occurrences : 1,
            error: nil
          }
        rescue Errno::EACCES => e
          { error: "Permission denied: #{e.message}" }
        rescue StandardError => e
          { error: "Failed to edit file: #{e.message}" }
        end
      end

      private def try_smart_match(content, old_string)
        # Normalize whitespace: convert all leading whitespace to single space for comparison
        normalized_old = normalize_leading_whitespace(old_string)
        
        # Find all potential matches in content with normalized whitespace
        matches = []
        content_lines = content.lines
        old_lines = old_string.lines
        
        return nil if old_lines.empty?
        
        # Scan through content to find matches
        (0..content_lines.length - old_lines.length).each do |start_idx|
          slice = content_lines[start_idx, old_lines.length]
          next unless slice
          
          # Check if this slice matches when normalized
          if lines_match_normalized?(slice, old_lines)
            matched_string = slice.join
            matches << { start: start_idx, matched_string: matched_string }
          end
        end
        
        return nil if matches.empty?
        
        # Return the first match and count total occurrences
        {
          matched_string: matches.first[:matched_string],
          occurrences: matches.length
        }
      end

      private def normalize_leading_whitespace(text)
        # Normalize each line's leading whitespace
        text.lines.map { |line| line.sub(/^\s+/, ' ') }.join
      end

      private def lines_match_normalized?(lines1, lines2)
        return false unless lines1.length == lines2.length
        
        lines1.zip(lines2).all? do |line1, line2|
          # Normalize leading whitespace and compare
          norm1 = line1.sub(/^\s+/, ' ')
          norm2 = line2.sub(/^\s+/, ' ')
          norm1 == norm2
        end
      end

      private def build_helpful_error(content, old_string, path)
        # Find similar content to help debug
        old_lines = old_string.lines
        first_line_pattern = old_lines.first&.strip
        
        if first_line_pattern && !first_line_pattern.empty?
          # Find lines that match the first line (ignoring whitespace)
          content_lines = content.lines
          similar_locations = []
          
          content_lines.each_with_index do |line, idx|
            if line.strip == first_line_pattern
              # Show context: 2 lines before and after
              start_idx = [0, idx - 2].max
              end_idx = [content_lines.length - 1, idx + old_lines.length + 2].min
              context = content_lines[start_idx..end_idx].join
              
              similar_locations << {
                line_number: idx + 1,
                context: context
              }
            end
          end
          
          if similar_locations.any?
            context_preview = similar_locations.first[:context]
            # Escape newlines for better display
            context_display = context_preview.lines.first(5).map { |l| "  #{l}" }.join
            
            return {
              error: "String to replace not found in file. The first line of old_string exists at line #{similar_locations.first[:line_number]}, " \
                     "but the full multi-line string doesn't match. This is often caused by whitespace differences (tabs vs spaces). " \
                     "\n\nContext around line #{similar_locations.first[:line_number]}:\n#{context_display}\n\n" \
                     "TIP: Use file_reader to see the actual content, then retry. No need to explain, just execute the tools."
            }
          end
        end
        
        # Generic error if no similar content found
        {
          error: "String to replace not found in file '#{File.basename(path)}'. " \
                 "Make sure old_string matches exactly (including all whitespace). " \
                 "TIP: Use file_reader to view the exact content first, then retry. No need to explain, just execute the tools."
        }
      end

      def format_call(args)
        path = args[:file_path] || args['file_path'] || args[:path] || args['path']
        "Edit(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        replacements = result[:replacements] || result['replacements'] || 1
        "Modified #{replacements} occurrence#{replacements > 1 ? 's' : ''}"
      end
    end
  end
end
