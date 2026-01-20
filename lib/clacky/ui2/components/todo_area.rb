# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # TodoArea displays active todos above the separator line
      class TodoArea
        attr_accessor :height
        attr_reader :todos

        MAX_DISPLAY_TASKS = 2  # Show at most 2 tasks (Next + After)

        def initialize
          @todos = []
          @pastel = Pastel.new
          @width = TTY::Screen.width
          @height = 0  # Dynamic height based on todos
        end

        # Update todos list
        # @param todos [Array<Hash>] Array of todo items
        def update(todos)
          @todos = todos || []
          @pending_todos = @todos.select { |t| t[:status] == "pending" }
          @completed_count = @todos.count { |t| t[:status] == "completed" }
          @total_count = @todos.size

          # Height: 1 line for header + min(pending_count, MAX_DISPLAY_TASKS) lines for tasks
          if @pending_todos.empty? && @completed_count == 0
            @height = 0
          else
            display_count = [@pending_todos.size, MAX_DISPLAY_TASKS].min
            @height = 1 + display_count
          end
        end

        # Check if there are todos to display
        def visible?
          @height > 0
        end

        # Render todos area
        # @param start_row [Integer] Screen row to start rendering
        def render(start_row:)
          return unless visible?

          update_width

          # Render header: [##] Tasks [0/4]: ████
          move_cursor(start_row, 0)
          clear_line
          header = render_header
          print header

          # Render tasks (Next and After)
          @pending_todos.take(MAX_DISPLAY_TASKS).each_with_index do |todo, i|
            move_cursor(start_row + i + 1, 0)
            clear_line

            label = i == 0 ? "Next" : "After"
            task_text = truncate_text("##{todo[:id]} - #{todo[:task]}", @width - 12)
            line = "  #{@pastel.dim("->")} #{@pastel.yellow(label)}: #{task_text}"
            print line
          end

          flush
        end

        # Clear the area
        def clear
          @todos = []
          @pending_todos = []
          @completed_count = 0
          @total_count = 0
          @height = 0
        end

        private

        # Render header line with progress bar
        def render_header
          progress = "#{@completed_count}/#{@total_count}"
          progress_bar = render_progress_bar(@completed_count, @total_count)

          "#{@pastel.cyan("[##]")} Tasks [#{progress}]: #{progress_bar}"
        end

        # Render a simple progress bar
        def render_progress_bar(completed, total)
          return "" if total == 0

          bar_width = 10
          filled = total > 0 ? (completed.to_f / total * bar_width).round : 0
          empty = bar_width - filled

          filled_bar = @pastel.green("█" * filled)
          empty_bar = @pastel.dim("░" * empty)

          "#{filled_bar}#{empty_bar}"
        end

        # Truncate text to fit width
        def truncate_text(text, max_width)
          return "" if text.nil?

          if text.length > max_width
            text[0...(max_width - 3)] + "..."
          else
            text
          end
        end

        # Update width on resize
        def update_width
          @width = TTY::Screen.width
        end

        # Move cursor to position
        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        # Clear current line
        def clear_line
          print "\e[2K"
        end

        # Flush output
        def flush
          $stdout.flush
        end
      end
    end
  end
end
