# frozen_string_literal: true

require 'io/console'
require 'tty-prompt'
require_relative 'base_component'

module Clacky
  module UI2
    module Components
      # ModalComponent - Displays a centered modal dialog with form fields
      class ModalComponent < BaseComponent
        attr_reader :width, :height

        def initialize
          super
          @width = 70
          @height = 16
          @title = ""
          @fields = []
          @values = {}
        end

        # Configure and show the modal
        # @param title [String] Modal title
        # @param fields [Array<Hash>] Field definitions
        # @param validator [Proc, nil] Optional validation callback that receives values hash
        #                              Should return { success: true } or { success: false, error: "message" }
        # @return [Hash, nil] Hash of field values, or nil if cancelled
        def show(title:, fields:, validator: nil)
          @title = title
          @fields = fields
          @values = {}
          @error_message = nil

          # Get terminal size
          term_height, term_width = IO.console.winsize

          # Calculate modal position (centered)
          start_row = [(term_height - @height) / 2, 1].max
          start_col = [(term_width - @width) / 2, 1].max

          begin
            loop do
              # Draw modal background and border
              draw_modal(start_row, start_col)

              # Draw error message if present
              if @error_message
                draw_error_message(start_row + @height - 5, start_col)
              end

              # Draw instructions
              draw_buttons(start_row + @height - 3, start_col)
              
              # Collect input for each field
              current_row = start_row + 3
              @fields.each do |field|
                value = collect_field_input(field, current_row, start_col)
                if value == :cancelled
                  print "\e[?25l"  # Hide cursor
                  return nil  # User pressed Esc
                end
                @values[field[:name]] = value
                current_row += 2
              end

              # All fields collected - validate if validator provided
              if validator
                # Show "Testing..." message
                testing_row = start_row + @height - 5
                testing_col = start_col + 3
                print "\e[#{testing_row};#{testing_col}H\e[K"
                print @pastel.cyan("⏳ Testing connection...")
                STDOUT.flush
                
                validation_result = validator.call(@values)
                
                # Clear testing message
                print "\e[#{testing_row};#{testing_col}H\e[K"
                
                if validation_result[:success]
                  # Validation passed - hide cursor and return values
                  print "\e[?25l"
                  return @values
                else
                  # Validation failed - show error and loop again
                  @error_message = validation_result[:error] || "Validation failed"
                  # Clear modal to redraw with error
                  clear_modal(start_row, start_col)
                  sleep 1.5  # Give user time to read the error
                end
              else
                # No validator - return immediately
                print "\e[?25l"
                return @values
              end
            end
          ensure
            # Clear modal area
            clear_modal(start_row, start_col)
          end
        end

        # Render method (required by BaseComponent, not used for modal)
        def render(data)
          # Modal uses interactive show() method instead
          ""
        end

        private

        # Draw the modal background and border
        private def draw_modal(start_row, start_col)
          # Use theme colors - cyan for border, bright_cyan for title
          reset = "\e[0m"

          # Draw box with border
          @height.times do |i|
            print "\e[#{start_row + i};#{start_col}H"
            
            if i == 0
              # Top border with title
              title_text = " #{@title} "
              padding = (@width - title_text.length - 2) / 2
              remaining = @width - padding - title_text.length - 2
              border_line = @pastel.cyan("┌" + "─" * padding)
              title_part = @pastel.bright_cyan(title_text)
              border_rest = @pastel.cyan("─" * remaining + "┐")
              print border_line + title_part + border_rest
            elsif i == @height - 1
              # Bottom border
              print @pastel.cyan("└" + "─" * (@width - 2) + "┘")
            else
              # Side borders with background
              left_border = @pastel.cyan("│")
              right_border = @pastel.cyan("│")
              print left_border + " " * (@width - 2) + right_border
            end
          end
        end

        # Collect input for a single field
        private def collect_field_input(field, row, col)
          require 'io/console'
          
          label_text = @pastel.white(field[:label])

          # Draw field label
          print "\e[#{row};#{col + 2}H#{label_text}"

          # Input field position
          input_row = row + 1
          input_col = col + 4
          input_width = @width - 8

          # Initialize input buffer with default value
          buffer = field[:default].to_s.dup
          cursor_pos = buffer.length
          placeholder = "Press Enter to keep current"

          # Show cursor for input
          print "\e[?25h"

          loop do
            # Draw input field with cursor or placeholder
            if buffer.empty?
              # Show placeholder in dim gray
              display_text = @pastel.dim(placeholder)
            elsif field[:mask]
              # Show masked input
              display_text = @pastel.cyan('*' * buffer.length)
            else
              # Show normal input
              display_text = @pastel.cyan(buffer)
            end
            
            # Clear line and draw input
            print "\e[#{input_row};#{input_col}H\e[K"
            print display_text
            
            # Position cursor and ensure it's visible
            visible_cursor_pos = [cursor_pos, input_width - 1].min
            print "\e[#{input_row};#{input_col + visible_cursor_pos}H"
            STDOUT.flush

            # Read character
            char = STDIN.getch

            case char
            when "\r", "\n"  # Enter - confirm input
              # Clear placeholder if input is empty
              if buffer.empty?
                print "\e[#{input_row};#{input_col}H\e[K"
              end
              # Don't hide cursor here - next field will reuse it
              return buffer
            when "\e"  # Escape sequence
              seq = STDIN.read_nonblock(2) rescue ''
              if seq.empty?
                # Just Esc key - cancel (hide cursor when cancelling)
                print "\e[?25l"
                return :cancelled
              elsif seq == '[C'  # Right arrow
                cursor_pos = [cursor_pos + 1, buffer.length].min
              elsif seq == '[D'  # Left arrow
                cursor_pos = [cursor_pos - 1, 0].max
              elsif seq == '[H'  # Home
                cursor_pos = 0
              elsif seq == '[F'  # End
                cursor_pos = buffer.length
              end
            when "\u007F", "\b"  # Backspace
              if cursor_pos > 0
                buffer[cursor_pos - 1] = ''
                cursor_pos -= 1
              end
            when "\u0003"  # Ctrl+C (hide cursor when cancelling)
              print "\e[?25l"
              return :cancelled
            when "\u0015"  # Ctrl+U - clear line
              buffer = ''
              cursor_pos = 0
            else
              # Regular character input
              if char.ord >= 32 && char.ord < 127
                buffer.insert(cursor_pos, char)
                cursor_pos += 1
              end
            end
          end
        end

        # Draw error message
        private def draw_error_message(row, col)
          max_width = @width - 6
          # Truncate error message if too long
          error_text = @error_message.length > max_width ? @error_message[0..max_width-4] + "..." : @error_message
          error_col = col + 3
          
          formatted = @pastel.red("⚠ #{error_text}")
          print "\e[#{row};#{error_col}H#{formatted}"
        end

        # Draw confirmation buttons
        private def draw_buttons(row, col)
          # Show instructions at bottom of modal
          buttons_text = "Press Enter after each field • Press Esc to cancel"
          button_col = col + (@width - buttons_text.length) / 2
          
          formatted = @pastel.dim(buttons_text)
          print "\e[#{row};#{button_col}H#{formatted}"
        end

        # Clear the modal area
        private def clear_modal(start_row, start_col)
          @height.times do |i|
            print "\e[#{start_row + i};#{start_col}H#{' ' * @width}"
          end
        end
      end
    end
  end
end
