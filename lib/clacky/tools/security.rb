# frozen_string_literal: true

require "shellwords"
require "json"
require "fileutils"
require_relative "../utils/trash_directory"
require_relative "../utils/encoding"

module Clacky
  module Tools
    # Pre-execution safety layer for shell-style commands.
    #
    # Design principle: protect against the handful of commands that are
    # irreversibly destructive or can compromise the host. Everything else
    # is the user's (or agent's) business. Over-protection burns tool-call
    # rounds and forces awkward work-arounds (e.g. the infamous "cp ~/.clacky
    # /xxx ./ ... Blocked: outside project directory" dance).
    #
    # Responsibilities (applied to the `command` string BEFORE it is handed
    # to a shell / PTY for execution):
    #
    #   1. Block hard-dangerous commands:       sudo, pkill clacky, eval, exec,
    #                                           `...`, $(...), | sh, | bash,
    #                                           redirect to /etc /usr /bin.
    #   2. Rewrite `rm` → `mv <file> <trash>`   so the file is recoverable.
    #   3. Rewrite `curl ... | bash` → save     script to a file for manual
    #                                           review instead of exec.
    #   4. Protect credential/secret files:     .env, .ssh/, .aws/ — block
    #                                           writes to these only. Other
    #                                           "project" files (Gemfile,
    #                                           README.md, package.json, …)
    #                                           are NOT protected — editing
    #                                           them is a normal dev task.
    #
    # Notes:
    #   - `cp`, `mv`, `mkdir`, `touch`, `echo` are allowed to touch ANY path
    #     (including outside the project root). The source of a `cp` is
    #     read-only to the FS, and writing to arbitrary dirs is a legitimate
    #     need (copying from ~/.clacky/skills/..., writing to /tmp, etc.).
    #
    # Raises SecurityError on block. Returns a (possibly rewritten) command
    # string on success.
    #
    # This module was extracted from the former `SafeShell` tool. It is now
    # shared by any tool that executes shell-style commands (currently:
    # `terminal`).
    module Security
      # Raised when a command cannot be made safe.
      class Blocked < StandardError; end

      # Read-only commands that are considered safe for auto-execution
      # (permission mode :confirm_safes).
      SAFE_READONLY_COMMANDS = %w[
        ls pwd cat less more head tail
        grep find which whereis whoami
        ps top htop df du
        git echo printf wc
        date file stat
        env printenv
        curl wget
      ].freeze

      class << self
        # Process `command` and return a (possibly rewritten) safe version.
        # Raises SecurityError when the command cannot be made safe.
        #
        # @param command [String] command to check
        # @param project_root [String] path treated as the allowed root for writes
        # @return [String] safe command to execute
        def make_safe(command, project_root: Dir.pwd)
          Replacer.new(project_root).make_command_safe(command)
        end

        # True iff the command is safe to auto-execute in :confirm_safes mode.
        # (Either a known read-only command, or one that Security.make_safe
        # returns unchanged.)
        def command_safe_for_auto_execution?(command)
          return false unless command

          cmd_name = command.strip.split.first
          return true if SAFE_READONLY_COMMANDS.include?(cmd_name)

          begin
            safe = make_safe(command, project_root: Dir.pwd)
            command.strip == safe.strip
          rescue SecurityError
            false
          end
        end
      end

      # Internal class that owns per-project state (trash dir, log dir, ...).
      # Extracted almost verbatim from the old SafeShell::CommandSafetyReplacer.
      class Replacer
        def initialize(project_root)
          @project_root = File.expand_path(project_root)

          trash_directory = Clacky::TrashDirectory.new(@project_root)
          @trash_dir  = trash_directory.trash_dir
          @backup_dir = trash_directory.backup_dir

          @project_hash = trash_directory.generate_project_hash(@project_root)
          @safety_log_dir = File.join(Dir.home, ".clacky", "safety_logs", @project_hash)
          FileUtils.mkdir_p(@safety_log_dir) unless Dir.exist?(@safety_log_dir)
          @safety_log_file = File.join(@safety_log_dir, "safety.log")
        end

        def make_command_safe(command)
          command = command.strip

          # Use a UTF-8-scrubbed copy ONLY for regex checks.  The original
          # bytes are returned unchanged so the shell receives exact paths
          # (e.g. GBK-encoded Chinese filenames in zip archives).
          @safe_check_command = Clacky::Utils::Encoding.safe_check(command)

          case @safe_check_command
          when /pkill.*clacky|killall.*clacky|kill\s+.*\bclacky\b/i
            raise SecurityError, "Killing the clacky server process is not allowed. To restart, use: kill -USR1 $CLACKY_MASTER_PID"
          when /clacky\s+server/
            raise SecurityError, "Managing the clacky server from within a session is not allowed. To restart, use: kill -USR1 $CLACKY_MASTER_PID"
          when /^rm\s+/
            replace_rm_command(command)
          when /^chmod\s+x/
            replace_chmod_command(command)
          when /^curl.*\|\s*(sh|bash)/
            replace_curl_pipe_command(command)
          when /^sudo\s+/
            block_sudo_command(command)
          when />\s*\/dev\/null\s*$/
            allow_dev_null_redirect(command)
          when /^(mv|cp|mkdir|touch|echo)\s+/
            validate_and_allow(command)
          else
            validate_general_command(@safe_check_command)
            command
          end
        end

        def replace_rm_command(command)
          files = parse_rm_files(command)
          raise SecurityError, "No files specified for deletion" if files.empty?

          commands = files.map do |file|
            validate_file_path(file)

            timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%N")
            safe_name = "#{File.basename(file)}_deleted_#{timestamp}"
            trash_path = File.join(@trash_dir, safe_name)

            create_delete_metadata(file, trash_path) if File.exist?(file)

            "mv #{Shellwords.escape(file)} #{Shellwords.escape(trash_path)}"
          end

          result = commands.join(' && ')
          log_replacement("rm", result, "Files moved to trash instead of permanent deletion")
          result
        end

        def replace_chmod_command(command)
          begin
            parts = Shellwords.split(command)
          rescue ArgumentError
            parts = command.split(/\s+/)
          end

          files = parts[2..-1] || []
          files.each { |file| validate_file_path(file) unless file.start_with?('-') }

          log_replacement("chmod", command, "chmod +x is allowed - file permissions will be modified")
          command
        end

        def replace_curl_pipe_command(command)
          if command.match(/curl\s+(.*?)\s*\|\s*(sh|bash)/)
            url = $1
            shell_type = $2
            timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
            safe_file = File.join(@backup_dir, "downloaded_script_#{timestamp}.sh")

            result = "curl #{url} -o #{Shellwords.escape(safe_file)} && echo '🔒 Script downloaded to #{safe_file} for manual review. Run: cat #{safe_file}'"
            log_replacement("curl | #{shell_type}", result, "Script saved for manual review instead of automatic execution")
            result
          else
            command
          end
        end

        def block_sudo_command(_command)
          raise SecurityError, "sudo commands are not allowed for security reasons"
        end

        def allow_dev_null_redirect(command)
          command
        end

        # Relaxed validator for mv / cp / mkdir / touch / echo.
        #
        # Historical behavior was to forbid any path outside @project_root,
        # which broke legitimate workflows like copying skill templates from
        # ~/.clacky/skills/... into the project. We now only block writes to
        # true credential directories (.ssh, .aws) and .env files. Everything
        # else is allowed.
        def validate_and_allow(command)
          begin
            parts = Shellwords.split(command)
          rescue ArgumentError
            parts = command.split(/\s+/)
          end

          cmd  = parts.first
          args = parts[1..-1] || []

          case cmd
          when 'mv', 'cp'
            # For mv/cp only the DESTINATION (last non-flag arg) is a write
            # target; earlier args are sources and are read-only to the FS.
            write_targets = args.reject { |a| a.start_with?('-') }
            dest = write_targets.last
            validate_secret_write(dest) if dest
          when 'mkdir', 'touch'
            args.each { |path| validate_secret_write(path) unless path.start_with?('-') }
          when 'echo'
            # `echo foo > path` — best-effort: block only if redirecting to a
            # secret path. The redirect target will also be caught by
            # validate_general_command for /etc /usr /bin; here we add .env,
            # .ssh/, .aws/.
            if command =~ />\s*([^\s|&;]+)/
              validate_secret_write(Regexp.last_match(1))
            end
          end

          command
        end

        def validate_general_command(command)
          cmd_without_quotes = command.gsub(/'[^']*'|"[^"]*"/, '')

          dangerous_patterns = [
            /eval\s*\(/,
            /exec\s*\(/,
            /system\s*\(/,
            /`[^`]+`/,
            /\$\([^)]+\)/,
            /\|\s*sh\s*$/,
            /\|\s*bash\s*$/,
            />\s*\/etc\//,
            />\s*\/usr\//,
            />\s*\/bin\//
          ]

          dangerous_patterns.each do |pattern|
            if cmd_without_quotes.match?(pattern)
              raise SecurityError, "Dangerous command pattern detected: #{pattern.source}"
            end
          end

          command
        end

        def parse_rm_files(command)
          begin
            parts = Shellwords.split(command)
          rescue ArgumentError
            parts = command.split(/\s+/)
          end

          parts.drop(1).reject { |part| part.start_with?('-') }
        end

        # Block writes that would clobber credentials / secrets.
        # These are the only paths truly dangerous to write to by accident:
        #   - ~/.ssh/*          (SSH private keys)
        #   - ~/.aws/*          (AWS credentials)
        #   - any *.env file    (API keys, DB URLs, etc.)
        #
        # Paths in / outside the project root, Gemfile, README, package.json,
        # etc. are all allowed — the agent is expected to edit them normally.
        SECRET_WRITE_PATTERNS = [
          %r{(?:\A|/)\.ssh/},
          %r{(?:\A|/)\.aws/},
          /(?:\A|\/)\.env(?:\.|\z)/,
          /\.env\z/
        ].freeze

        def validate_secret_write(path)
          return if path.nil? || path.empty? || path.start_with?('-')

          expanded_path = File.expand_path(path)

          SECRET_WRITE_PATTERNS.each do |pattern|
            if expanded_path.match?(pattern)
              raise SecurityError,
                    "Write to credential/secret path blocked: #{path} " \
                    "(matched protected pattern). If intentional, edit the " \
                    "file manually outside the agent."
            end
          end
        end

        # Kept for `rm` handler — which rewrites rm → mv-to-trash. We still
        # want to prevent accidentally trashing a secret file.
        def validate_file_path(path)
          validate_secret_write(path)
        end

        def create_delete_metadata(original_path, trash_path)
          metadata = {
            original_path: File.expand_path(original_path),
            project_root: @project_root,
            trash_directory: File.dirname(trash_path),
            deleted_at: Time.now.iso8601,
            deleted_by: 'AI_Terminal',
            file_size: File.size(original_path),
            file_type: File.extname(original_path),
            file_mode: File.stat(original_path).mode.to_s(8)
          }

          metadata_file = "#{trash_path}.metadata.json"
          File.write(metadata_file, JSON.pretty_generate(metadata))
        rescue StandardError => e
          log_warning("Failed to create metadata for #{original_path}: #{e.message}")
        end

        def log_replacement(original, replacement, reason)
          write_log(
            action: 'command_replacement',
            original_command: original,
            safe_replacement: replacement,
            reason: reason
          )
        end

        def log_warning(message)
          write_log(action: 'warning', message: message)
        end

        def write_log(**fields)
          log_entry = { timestamp: Time.now.iso8601 }.merge(fields)
          File.open(@safety_log_file, 'a') { |f| f.puts JSON.generate(log_entry) }
        rescue StandardError
          # Logging must never break main functionality.
        end

        private :replace_rm_command, :replace_chmod_command,
                :replace_curl_pipe_command, :block_sudo_command,
                :allow_dev_null_redirect, :validate_and_allow,
                :validate_general_command, :parse_rm_files,
                :validate_file_path, :validate_secret_write,
                :create_delete_metadata, :log_replacement,
                :log_warning, :write_log
      end
    end
  end
end
