# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # ClaudeCode environment variable compatibility layer
  # Provides configuration detection from ClaudeCode's environment variables
  module ClaudeCodeEnv
    # Environment variable names used by ClaudeCode
    ENV_API_KEY = "ANTHROPIC_API_KEY"
    ENV_AUTH_TOKEN = "ANTHROPIC_AUTH_TOKEN"
    ENV_BASE_URL = "ANTHROPIC_BASE_URL"

    # Default Anthropic API endpoint
    DEFAULT_BASE_URL = "https://api.anthropic.com"

    class << self
      # Check if any ClaudeCode authentication is configured
      def configured?
        !api_key.nil? && !api_key.empty?
      end

      # Get API key - prefer ANTHROPIC_API_KEY, fallback to ANTHROPIC_AUTH_TOKEN
      def api_key
        if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
          ENV[ENV_API_KEY]
        elsif ENV[ENV_AUTH_TOKEN] && !ENV[ENV_AUTH_TOKEN].empty?
          ENV[ENV_AUTH_TOKEN]
        end
      end

      # Get base URL from environment, or return default Anthropic API URL
      def base_url
        ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty? ? ENV[ENV_BASE_URL] : DEFAULT_BASE_URL
      end

      # Get configuration as a hash (includes configured values)
      # Returns api_key and base_url (always available as there's a default)
      def to_h
        {
          "api_key" => api_key,
          "base_url" => base_url
        }.compact
      end
    end
  end

  class Config
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    # Default model for ClaudeCode environment
    CLAUDE_DEFAULT_MODEL = "claude-sonnet-4-5"

    attr_accessor :api_key, :model, :base_url, :config_source

    def initialize(data = {})
      @api_key = data["api_key"]
      @model = data["model"]
      @base_url = data["base_url"] || "https://api.openai.com"
      @config_source = data["_config_source"] || "default"
    end

    def self.load(config_file = CONFIG_FILE)
      # Load from config file first
      if File.exist?(config_file)
        data = YAML.load_file(config_file) || {}
        config_source = "file"
      else
        data = {}
        config_source = nil
      end

      # If api_key not found in config file, check ClaudeCode environment variables
      if data["api_key"].nil? || data["api_key"].empty?
        if ClaudeCodeEnv.configured?
          data["api_key"] = ClaudeCodeEnv.api_key
          data["base_url"] = ClaudeCodeEnv.base_url if data["base_url"].nil? || data["base_url"].empty?
          # Use Claude default model if not specified in config file
          data["model"] = CLAUDE_DEFAULT_MODEL if data["model"].nil? || data["model"].empty?
          config_source = "claude_code"
        elsif config_source.nil?
          config_source = "default"
        end
      elsif config_source.nil?
        # Config file existed but didn't have api_key
        config_source = "default"
      end

      data["_config_source"] = config_source
      new(data)
    end

    def save(config_file = CONFIG_FILE)
      config_dir = File.dirname(config_file)
      FileUtils.mkdir_p(config_dir)
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    def to_yaml
      YAML.dump({
        "api_key" => @api_key,
        "model" => @model,
        "base_url" => @base_url
      })
    end
  end
end
