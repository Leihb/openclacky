# frozen_string_literal: true

require "io/console"
require "pastel"
require "tty-screen"
require "tempfile"
require "base64"

module Clacky
  module UI
    # Enhanced input prompt with multi-line support and image paste
    # 
    # Features:
    # - Shift+Enter: Add new line
    # - Enter: Submit message
    # - Ctrl+V: Paste text or images from clipboard
    # - Image preview and management
    class EnhancedPrompt
      attr_reader :images

      def initialize
        @pastel = Pastel.new
        @images = [] # Array of image file paths
        @paste_counter = 0 # Counter for paste operations
        @paste_placeholders = {} # Map of placeholder text to actual pasted content
        @last_input_time = nil # Track last input time for rapid input detection
        @rapid_input_threshold = 0.01 # 10ms threshold for detecting paste-like rapid input
      end

      # Read user input with enhanced features
      # @param prefix [String] Prompt prefix (default: "You:")
      # @return [Hash, nil] { text: String, images: Array } or nil on EOF
      def read_input(prefix: "You:")
        @images = []
        lines = []
        cursor_pos = 0
        line_index = 0
        @last_ctrl_c_time = nil  # Track when Ctrl+C was last pressed

        loop do
          # Display the prompt box
          display_prompt_box(lines, prefix, line_index, cursor_pos)

          # Read a single character/key
          begin
            key = read_key_with_rapid_detection
          rescue Interrupt
            return nil
          end
          
          # Handle buffered rapid input (system paste detection)
          if key.is_a?(Hash) && key[:type] == :rapid_input
            pasted_text = key[:text]
            pasted_lines = pasted_text.split("\n")
            
            if pasted_lines.size > 1
              # Multi-line rapid input - use placeholder for display
              @paste_counter += 1
              placeholder = "[##{@paste_counter} Paste Text]"
              @paste_placeholders[placeholder] = pasted_text
              
              # Insert placeholder at cursor position
              chars = (lines[line_index] || "").chars
              placeholder_chars = placeholder.chars
              chars.insert(cursor_pos, *placeholder_chars)
              lines[line_index] = chars.join
              cursor_pos += placeholder_chars.length
            else
              # Single line rapid input - insert at cursor (use chars for UTF-8)
              chars = (lines[line_index] || "").chars
              pasted_chars = pasted_text.chars
              chars.insert(cursor_pos, *pasted_chars)
              lines[line_index] = chars.join
              cursor_pos += pasted_chars.length
            end
            next
          end

          case key
          when "\n" # Shift+Enter - newline (Linux/Mac sends \n for Shift+Enter in some terminals)
            # Add new line
            if lines[line_index]
              # Split current line at cursor (use chars for UTF-8)
              chars = lines[line_index].chars
              lines[line_index] = chars[0...cursor_pos].join
              lines.insert(line_index + 1, chars[cursor_pos..-1].join || "")
            else
              lines.insert(line_index + 1, "")
            end
            line_index += 1
            cursor_pos = 0

          when "\r" # Enter - submit
            # Submit if not empty
            unless lines.join.strip.empty? && @images.empty?
              clear_prompt_display(lines.size)
              # Replace placeholders with actual pasted content
              final_text = expand_placeholders(lines.join("\n"))
              return { text: final_text, images: @images.dup }
            end

          when "\u0003" # Ctrl+C
            # Check if input is empty
            has_content = lines.any? { |line| !line.strip.empty? } || @images.any?
            
            if has_content
              # Input has content - clear it on first Ctrl+C
              current_time = Time.now.to_f
              time_since_last = @last_ctrl_c_time ? (current_time - @last_ctrl_c_time) : Float::INFINITY
              
              if time_since_last < 2.0  # Within 2 seconds of last Ctrl+C
                # Second Ctrl+C within 2 seconds - exit
                clear_prompt_display(lines.size)
                return nil
              else
                # First Ctrl+C - clear content
                @last_ctrl_c_time = current_time
                lines = []
                @images = []
                cursor_pos = 0
                line_index = 0
                @paste_counter = 0
                @paste_placeholders = {}
              end
            else
              # Input is empty - exit immediately
              clear_prompt_display(lines.size)
              return nil
            end

          when "\u0016" # Ctrl+V - Paste
            pasted = paste_from_clipboard
            if pasted[:type] == :image
              # Save image and add to list
              @images << pasted[:path]
            else
              # Handle pasted text
              pasted_text = pasted[:text]
              pasted_lines = pasted_text.split("\n")
              
              if pasted_lines.size > 1
                # Multi-line paste - use placeholder for display
                @paste_counter += 1
                placeholder = "[##{@paste_counter} Paste Text]"
                @paste_placeholders[placeholder] = pasted_text
                
                # Insert placeholder at cursor position
                chars = (lines[line_index] || "").chars
                placeholder_chars = placeholder.chars
                chars.insert(cursor_pos, *placeholder_chars)
                lines[line_index] = chars.join
                cursor_pos += placeholder_chars.length
              else
                # Single line paste - insert at cursor (use chars for UTF-8)
                chars = (lines[line_index] || "").chars
                pasted_chars = pasted_text.chars
                chars.insert(cursor_pos, *pasted_chars)
                lines[line_index] = chars.join
                cursor_pos += pasted_chars.length
              end
            end

          when "\u007F", "\b" # Backspace
            if cursor_pos > 0
              # Delete character before cursor (use chars for UTF-8)
              chars = (lines[line_index] || "").chars
              chars.delete_at(cursor_pos - 1)
              lines[line_index] = chars.join
              cursor_pos -= 1
            elsif line_index > 0
              # Join with previous line
              prev_line = lines[line_index - 1]
              current_line = lines[line_index]
              lines.delete_at(line_index)
              line_index -= 1
              cursor_pos = prev_line.chars.length
              lines[line_index] = prev_line + current_line
            end

          when "\e[A" # Up arrow
            if line_index > 0
              line_index -= 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[B" # Down arrow
            if line_index < lines.size - 1
              line_index += 1
              cursor_pos = [cursor_pos, (lines[line_index] || "").chars.length].min
            end

          when "\e[C" # Right arrow
            current_line = lines[line_index] || ""
            cursor_pos = [cursor_pos + 1, current_line.chars.length].min

          when "\e[D" # Left arrow
            cursor_pos = [cursor_pos - 1, 0].max

          when "\u0004" # Ctrl+D - Delete image by number
            if @images.any?
              print "\nEnter image number to delete (1-#{@images.size}): "
              num = STDIN.gets.to_i
              if num > 0 && num <= @images.size
                @images.delete_at(num - 1)
              end
            end

          else
            # Regular character input - support UTF-8
            if key.length >= 1 && key != "\e" && !key.start_with?("\e") && key.ord >= 32
              lines[line_index] ||= ""
              current_line = lines[line_index]
              
              # Insert character at cursor position (using character index, not byte index)
              chars = current_line.chars
              chars.insert(cursor_pos, key)
              lines[line_index] = chars.join
              cursor_pos += 1
            end
          end

          # Ensure we have at least one line
          lines << "" if lines.empty?
        end
      end

      private

      # Expand placeholders to actual pasted content
      def expand_placeholders(text)
        result = text.dup
        @paste_placeholders.each do |placeholder, actual_content|
          result.gsub!(placeholder, actual_content)
        end
        result
      end

      # Display the prompt box with images and input
      def display_prompt_box(lines, prefix, line_index, cursor_pos)
        width = TTY::Screen.width - 4  # Use full terminal width (minus 4 for borders)

        # Clear previous display if exists
        if @last_display_lines && @last_display_lines > 0
          # Move cursor up and clear each line
          @last_display_lines.times do
            print "\e[1A"  # Move up one line
            print "\e[2K"  # Clear entire line
          end
          print "\r"  # Move to beginning of line
        end

        lines_to_display = []

        # Display images if any
        if @images.any?
          lines_to_display << @pastel.dim("╭─ Attached Images " + "─" * (width - 19) + "╮")
          @images.each_with_index do |img_path, idx|
            filename = File.basename(img_path)
            # Check if file exists before getting size
            filesize = File.exist?(img_path) ? format_filesize(File.size(img_path)) : "N/A"
            line_content = " #{idx + 1}. #{filename} (#{filesize})"
            display_content = line_content.ljust(width - 2)
            lines_to_display << @pastel.dim("│ ") + display_content + @pastel.dim(" │")
          end
          lines_to_display << @pastel.dim("╰" + "─" * width + "╯")
          lines_to_display << ""
        end

        # Display input box
        hint = "Shift+Enter:newline | Enter:submit | Ctrl+C:cancel"
        lines_to_display << @pastel.dim("╭─ Message " + "─" * (width - 10) + "╮")
        hint_line = @pastel.dim(hint)
        padding = " " * [(width - hint.length - 2), 0].max
        lines_to_display << @pastel.dim("│ ") + hint_line + padding + @pastel.dim(" │")
        lines_to_display << @pastel.dim("├" + "─" * width + "┤")

        # Display input lines with word wrap
        display_lines = lines.empty? ? [""] : lines
        max_display_lines = 15 # Show up to 15 wrapped lines
        
        # Flatten all lines with word wrap
        wrapped_display_lines = []
        line_to_wrapped_mapping = [] # Track which original line each wrapped line belongs to
        
        display_lines.each_with_index do |line, original_idx|
          line_chars = line.chars
          content_width = width - 2 # Available width for content (excluding borders)
          
          if line_chars.length <= content_width
            # Line fits in one display line
            wrapped_display_lines << { text: line, original_line: original_idx, start_pos: 0 }
          else
            # Line needs wrapping
            start_pos = 0
            while start_pos < line_chars.length
              chunk_chars = line_chars[start_pos...[start_pos + content_width, line_chars.length].min]
              wrapped_display_lines << { 
                text: chunk_chars.join, 
                original_line: original_idx, 
                start_pos: start_pos 
              }
              start_pos += content_width
            end
          end
        end
        
        # Find which wrapped line contains the cursor
        cursor_wrapped_line_idx = 0
        cursor_in_wrapped_pos = cursor_pos
        content_width = width - 2
        
        # Find all wrapped lines for the current line_index
        current_line_wrapped = wrapped_display_lines.select.with_index { |wl, idx| wl[:original_line] == line_index }
        
        if current_line_wrapped.any?
          # Iterate through wrapped lines to find where cursor belongs
          accumulated_chars = 0
          found = false
          
          current_line_wrapped.each_with_index do |wrapped_line, local_idx|
            line_start = wrapped_line[:start_pos]
            line_length = wrapped_line[:text].chars.length
            line_end = line_start + line_length
            
            # Find global index of this wrapped line
            global_idx = wrapped_display_lines.index { |wl| wl == wrapped_line }
            
            if cursor_pos >= line_start && cursor_pos < line_end
              # Cursor is within this wrapped line
              cursor_wrapped_line_idx = global_idx
              cursor_in_wrapped_pos = cursor_pos - line_start
              found = true
              break
            elsif cursor_pos == line_end && local_idx == current_line_wrapped.length - 1
              # Cursor is at the very end of the last wrapped line for this line_index
              cursor_wrapped_line_idx = global_idx
              cursor_in_wrapped_pos = line_length
              found = true
              break
            end
          end
          
          # Fallback: if not found, place cursor at the end of the last wrapped line
          unless found
            last_wrapped = current_line_wrapped.last
            cursor_wrapped_line_idx = wrapped_display_lines.index { |wl| wl == last_wrapped }
            cursor_in_wrapped_pos = last_wrapped[:text].chars.length
          end
        end
        
        # Determine which wrapped lines to display (centered around cursor)
        if wrapped_display_lines.size <= max_display_lines
          display_start = 0
          display_end = wrapped_display_lines.size - 1
        else
          # Center view around cursor line
          half_display = max_display_lines / 2
          display_start = [cursor_wrapped_line_idx - half_display, 0].max
          display_end = [display_start + max_display_lines - 1, wrapped_display_lines.size - 1].min
          
          # Adjust if we're near the end
          if display_end - display_start < max_display_lines - 1
            display_start = [display_end - max_display_lines + 1, 0].max
          end
        end
        
        # Display the wrapped lines
        (display_start..display_end).each do |idx|
          wrapped_line = wrapped_display_lines[idx]
          line_text = wrapped_line[:text]
          line_chars = line_text.chars
          content_width = width - 2
          
          # Pad to full width
          display_line = line_text.ljust(content_width)
          
          if idx == cursor_wrapped_line_idx
            # Show cursor on this wrapped line
            before_cursor = line_chars[0...cursor_in_wrapped_pos].join
            cursor_char = line_chars[cursor_in_wrapped_pos] || " "
            after_cursor_chars = line_chars[(cursor_in_wrapped_pos + 1)..-1]
            after_cursor = after_cursor_chars ? after_cursor_chars.join : ""
            
            # Calculate padding
            content_length = before_cursor.length + 1 + after_cursor.length
            padding = " " * [content_width - content_length, 0].max
            
            line_display = before_cursor + @pastel.on_white(@pastel.black(cursor_char)) + after_cursor + padding
            lines_to_display << @pastel.dim("│ ") + line_display + @pastel.dim(" │")
          else
            lines_to_display << @pastel.dim("│ ") + display_line + @pastel.dim(" │")
          end
        end
        
        # Show scroll indicator if needed
        if wrapped_display_lines.size > max_display_lines
          scroll_info = " (#{display_start + 1}-#{display_end + 1}/#{wrapped_display_lines.size} lines) "
          lines_to_display << @pastel.dim("│#{scroll_info.center(width)}│")
        end

        # Footer - calculate width properly
        footer_text = "Line #{line_index + 1}/#{display_lines.size} | Char #{cursor_pos}/#{(display_lines[line_index] || "").chars.length}"
        # Total width = "╰─ " (3) + footer_text + " ─...─╯" (width - 3 - footer_text.length)
        remaining_width = width - footer_text.length - 3  # 3 = "╰─ " length
        footer_line = @pastel.dim("╰─ ") + @pastel.dim(footer_text) + @pastel.dim(" ") + @pastel.dim("─" * [remaining_width - 1, 0].max) + @pastel.dim("╯")
        lines_to_display << footer_line
        
        # Output all lines at once (use print to avoid extra newline at the end)
        print lines_to_display.join("\n")
        print "\n"  # Add one controlled newline
        
        # Remember how many lines we displayed
        @last_display_lines = lines_to_display.size
      end

      # Clear prompt display after submission
      def clear_prompt_display(num_lines)
        # Clear the prompt box we just displayed
        if @last_display_lines && @last_display_lines > 0
          @last_display_lines.times do
            print "\e[1A"  # Move up one line
            print "\e[2K"  # Clear entire line
          end
          print "\r"  # Move to beginning of line
        end
      end

      # Read a single key press with escape sequence handling
      # Handles UTF-8 multi-byte characters correctly
      # Also detects rapid input (paste-like behavior)
      def read_key_with_rapid_detection
        $stdin.set_encoding('UTF-8')
        
        current_time = Time.now.to_f
        is_rapid_input = @last_input_time && (current_time - @last_input_time) < @rapid_input_threshold
        @last_input_time = current_time
        
        $stdin.raw do |io|
          io.set_encoding('UTF-8')  # Ensure IO encoding is UTF-8
          c = io.getc
          
          # Ensure character is UTF-8 encoded
          c = c.force_encoding('UTF-8') if c.is_a?(String) && c.encoding != Encoding::UTF_8
          
          # Handle escape sequences (arrow keys, special keys)
          if c == "\e"
            # Read the next 2 characters for escape sequences
            begin
              extra = io.read_nonblock(2)
              extra = extra.force_encoding('UTF-8') if extra.encoding != Encoding::UTF_8
              c = c + extra
            rescue IO::WaitReadable, Errno::EAGAIN
              # No more characters available
            end
            return c
          end
          
          # Check if there are more characters available using IO.select with timeout 0
          has_more_input = IO.select([io], nil, nil, 0)
          
          # If this is rapid input or there are more characters available
          if is_rapid_input || has_more_input
            # Buffer rapid input
            buffer = c.to_s.dup
            buffer.force_encoding('UTF-8')
            
            # Keep reading available characters
            loop do
              begin
                next_char = io.read_nonblock(1)
                next_char = next_char.force_encoding('UTF-8') if next_char.encoding != Encoding::UTF_8
                buffer << next_char
                
                # Continue only if more characters are immediately available
                break unless IO.select([io], nil, nil, 0)
              rescue IO::WaitReadable, Errno::EAGAIN
                break
              end
            end
            
            # Ensure buffer is UTF-8
            buffer.force_encoding('UTF-8')
            
            # If we buffered multiple characters or newlines, treat as rapid input (paste)
            if buffer.length > 1 || buffer.include?("\n") || buffer.include?("\r")
              # Remove any trailing \r or \n from rapid input buffer
              cleaned_buffer = buffer.gsub(/[\r\n]+\z/, '')
              return { type: :rapid_input, text: cleaned_buffer } if cleaned_buffer.length > 0
            end
            
            # Single character rapid input, return as-is
            return buffer[0] if buffer.length == 1
          end
          
          c
        end
      rescue Errno::EINTR
        "\u0003" # Treat interrupt as Ctrl+C
      end
      
      # Legacy method for compatibility
      def read_key
        read_key_with_rapid_detection
      end

      # Paste from clipboard (cross-platform)
      # @return [Hash] { type: :text/:image, text: String, path: String }
      def paste_from_clipboard
        case RbConfig::CONFIG["host_os"]
        when /darwin/i
          paste_from_clipboard_macos
        when /linux/i
          paste_from_clipboard_linux
        when /mswin|mingw|cygwin/i
          paste_from_clipboard_windows
        else
          { type: :text, text: "" }
        end
      end

      # Paste from macOS clipboard
      def paste_from_clipboard_macos
        require 'shellwords'
        require 'fileutils'
        
        # First check if there's an image in clipboard
        # Use osascript to check clipboard content type
        has_image = system("osascript -e 'try' -e 'the clipboard as «class PNGf»' -e 'on error' -e 'return false' -e 'end try' >/dev/null 2>&1")
        
        if has_image
          # Create a persistent temporary file (won't be auto-deleted)
          temp_dir = Dir.tmpdir
          temp_filename = "clipboard-#{Time.now.to_i}-#{rand(10000)}.png"
          temp_path = File.join(temp_dir, temp_filename)
          
          # Extract image using osascript
          script = <<~APPLESCRIPT
            set png_data to the clipboard as «class PNGf»
            set the_file to open for access POSIX file "#{temp_path}" with write permission
            write png_data to the_file
            close access the_file
          APPLESCRIPT
          
          success = system("osascript", "-e", script, out: File::NULL, err: File::NULL)
          
          if success && File.exist?(temp_path) && File.size(temp_path) > 0
            return { type: :image, path: temp_path }
          end
        end

        # No image, try text - ensure UTF-8 encoding
        text = `pbpaste 2>/dev/null`.to_s
        text.force_encoding('UTF-8')
        # Replace invalid UTF-8 sequences with replacement character
        text = text.encode('UTF-8', invalid: :replace, undef: :replace)
        { type: :text, text: text }
      rescue => e
        # Fallback to empty text on error
        { type: :text, text: "" }
      end

      # Paste from Linux clipboard
      def paste_from_clipboard_linux
        require 'shellwords'
        
        # Check if xclip is available
        if system("which xclip >/dev/null 2>&1")
          # Try to get image first
          temp_file = Tempfile.new(["clipboard-", ".png"])
          temp_file.close
          
          # Try different image MIME types
          ["image/png", "image/jpeg", "image/jpg"].each do |mime_type|
            if system("xclip -selection clipboard -t #{mime_type} -o > #{Shellwords.escape(temp_file.path)} 2>/dev/null")
              if File.size(temp_file.path) > 0
                return { type: :image, path: temp_file.path }
              end
            end
          end
          
          # No image, get text - ensure UTF-8 encoding
          text = `xclip -selection clipboard -o 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        elsif system("which xsel >/dev/null 2>&1")
          # Fallback to xsel for text only
          text = `xsel --clipboard --output 2>/dev/null`.to_s
          text.force_encoding('UTF-8')
          text = text.encode('UTF-8', invalid: :replace, undef: :replace)
          { type: :text, text: text }
        else
          { type: :text, text: "" }
        end
      rescue => e
        { type: :text, text: "" }
      end

      # Paste from Windows clipboard
      def paste_from_clipboard_windows
        # Try to get image using PowerShell
        temp_file = Tempfile.new(["clipboard-", ".png"])
        temp_file.close
        
        ps_script = <<~POWERSHELL
          Add-Type -AssemblyName System.Windows.Forms
          $img = [Windows.Forms.Clipboard]::GetImage()
          if ($img) {
            $img.Save('#{temp_file.path.gsub("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
            exit 0
          } else {
            exit 1
          }
        POWERSHELL
        
        success = system("powershell", "-NoProfile", "-Command", ps_script, out: File::NULL, err: File::NULL)
        
        if success && File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          return { type: :image, path: temp_file.path }
        end

        # No image, get text - ensure UTF-8 encoding
        text = `powershell -NoProfile -Command "Get-Clipboard" 2>nul`.to_s
        text.force_encoding('UTF-8')
        text = text.encode('UTF-8', invalid: :replace, undef: :replace)
        { type: :text, text: text }
      rescue => e
        { type: :text, text: "" }
      end

      # Format file size for display
      def format_filesize(size)
        if size < 1024
          "#{size}B"
        elsif size < 1024 * 1024
          "#{(size / 1024.0).round(1)}KB"
        else
          "#{(size / 1024.0 / 1024.0).round(1)}MB"
        end
      end
    end
  end
end
