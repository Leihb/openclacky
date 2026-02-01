# frozen_string_literal: true

require_relative "base_theme"

module Clacky
  module UI2
    module Themes
      # HackerTheme - Matrix/hacker-style with bracket symbols
      class HackerTheme < BaseTheme
        SYMBOLS = {
          user: "[>>]",
          assistant: "[<<]",
          tool_call: "[=>]",
          tool_result: "[<=]",
          tool_denied: "[!!]",
          tool_planned: "[??]",
          tool_error: "[XX]",
          thinking: "[..]",
          working: "[..]",
          success: "[OK]",
          error: "[ER]",
          warning: "[!!]",
          info: "[--]",
          task: "[##]",
          progress: "[>>]",
          file: "[F]",
          command: "[C]",
          cached: "[*]"
        }.freeze

        COLORS = {
          user: [:white, :white],
          assistant: [:bright_green, :white],
          tool_call: [:bright_cyan, :cyan],
          tool_result: [:bright_cyan, :cyan],
          tool_denied: [:bright_yellow, :yellow],
          tool_planned: [:bright_cyan, :cyan],
          tool_error: [:bright_red, :red],
          thinking: [:dim, :dim],
          working: [:bright_yellow, :yellow],
          success: [:bright_green, :green],
          error: [:bright_red, :red],
          warning: [:bright_yellow, :yellow],
          info: [:bright_white, :white],
          task: [:bright_yellow, :white],
          progress: [:bright_cyan, :cyan],
          file: [:cyan, :white],
          command: [:cyan, :white],
          cached: [:cyan, :cyan]
        }.freeze

        def name
          "hacker"
        end
      end
    end
  end
end
