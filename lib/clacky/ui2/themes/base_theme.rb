# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Themes
      # BaseTheme defines the abstract interface for all themes
      # Subclasses MUST define SYMBOLS and COLORS constants
      class BaseTheme
        def initialize
          @pastel = Pastel.new
          validate_theme_definition!
        end

        # Get all symbols defined by this theme
        # @return [Hash] Symbol definitions
        def symbols
          self.class::SYMBOLS
        end

        # Get all colors defined by this theme
        # @return [Hash] Color definitions
        def colors
          self.class::COLORS
        end

        # Get symbol for a specific key
        # @param key [Symbol] Symbol key
        # @return [String] Symbol string
        def symbol(key)
          symbols[key] || "[??]"
        end

        # Get symbol color for a specific key
        # @param key [Symbol] Color key
        # @return [Symbol] Pastel color method name
        def symbol_color(key)
          colors.dig(key, 0) || :white
        end

        # Get text color for a specific key
        # @param key [Symbol] Color key
        # @return [Symbol] Pastel color method name
        def text_color(key)
          colors.dig(key, 1) || :white
        end

        # Format symbol with its color
        # @param key [Symbol] Symbol key (e.g., :user, :assistant)
        # @return [String] Colored symbol
        def format_symbol(key)
          @pastel.public_send(symbol_color(key), symbol(key))
        end

        # Format text with color for given key
        # @param text [String] Text to format
        # @param key [Symbol] Color key (e.g., :user, :assistant)
        # @return [String] Colored text
        def format_text(text, key)
          @pastel.public_send(text_color(key), text)
        end

        # Theme name for display (subclasses should override)
        # @return [String] Theme name
        def name
          raise NotImplementedError, "Subclass must implement #name method"
        end

        private

        # Validate that subclass has defined required constants
        def validate_theme_definition!
          unless self.class.const_defined?(:SYMBOLS)
            raise NotImplementedError, "Theme #{self.class.name} must define SYMBOLS constant"
          end

          unless self.class.const_defined?(:COLORS)
            raise NotImplementedError, "Theme #{self.class.name} must define COLORS constant"
          end
        end
      end
    end
  end
end
