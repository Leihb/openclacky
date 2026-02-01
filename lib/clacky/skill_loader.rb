# frozen_string_literal: true

require "pathname"
require "fileutils"
require "clacky"

module Clacky
  # Loader and registry for skills.
  # Discovers skills from multiple locations and provides lookup functionality.
  class SkillLoader
    # Skill discovery locations (in priority order: lower index = lower priority)
    LOCATIONS = [
      :default,            # gem's built-in default skills (lowest priority)
      :global_claude,      # ~/.claude/skills/ (compatibility)
      :global_clacky,      # ~/.clacky/skills/
      :project_claude,     # .claude/skills/ (project-level compatibility)
      :project_clacky      # .clacky/skills/ (highest priority)
    ].freeze

    # Initialize the skill loader and automatically load all skills
    # @param working_dir [String] Current working directory for project-level discovery
    def initialize(working_dir = nil)
      @working_dir = working_dir || Dir.pwd
      @skills = {}           # Map identifier -> Skill
      @skills_by_command = {} # Map slash_command -> Skill
      @errors = []           # Store loading errors
      @loaded_from = {}      # Track which location each skill was loaded from
      
      # Automatically load all skills on initialization
      load_all
    end

    # Load all skills from configured locations
    # Clears previously loaded skills before loading to ensure idempotency
    # @return [Array<Skill>] Loaded skills
    def load_all
      # Clear existing skills to ensure idempotent reloading
      clear
      
      load_default_skills
      load_global_claude_skills
      load_global_clacky_skills
      load_project_claude_skills
      load_project_clacky_skills

      all_skills
    end

    # Load skills from ~/.claude/skills/ (lowest priority, compatibility)
    # @return [Array<Skill>]
    def load_global_claude_skills
      global_claude_dir = Pathname.new(ENV.fetch("HOME", "~")).join(".claude", "skills")
      load_skills_from_directory(global_claude_dir, :global_claude)
    end

    # Load skills from ~/.clacky/skills/ (user global)
    # @return [Array<Skill>]
    def load_global_clacky_skills
      global_clacky_dir = Pathname.new(ENV.fetch("HOME", "~")).join(".clacky", "skills")
      load_skills_from_directory(global_clacky_dir, :global_clacky)
    end

    # Load skills from .claude/skills/ (project-level compatibility)
    # @return [Array<Skill>]
    def load_project_claude_skills
      project_claude_dir = Pathname.new(@working_dir).join(".claude", "skills")
      load_skills_from_directory(project_claude_dir, :project_claude)
    end

    # Load skills from .clacky/skills/ (project-level, highest priority)
    # @return [Array<Skill>]
    def load_project_clacky_skills
      project_clacky_dir = Pathname.new(@working_dir).join(".clacky", "skills")
      load_skills_from_directory(project_clacky_dir, :project_clacky)
    end

    # Load skills from nested .claude/skills/ directories (monorepo support)
    # @return [Array<Skill>]
    def load_nested_project_skills
      working_path = Pathname.new(@working_dir)

      # Find all nested .claude/skills/ directories
      nested_dirs = []
      begin
        Dir.glob("**/.claude/skills/", base: @working_dir).each do |relative_path|
          nested_dirs << working_path.join(relative_path)
        end
      rescue ArgumentError
        # Skip if working_dir contains special characters
      end

      # Filter out the main project .claude/skills/ (already loaded)
      main_project_skills = working_path.join(".claude", "skills").realpath

      nested_dirs.each do |dir|
        next if dir.realpath == main_project_skills

        # Determine the source path for priority resolution
        # Use the parent directory of .claude as the source
        source_path = dir.parent

        # Determine skill identifier based on relative path from working_dir
        relative_to_working = dir.relative_path_from(working_path).to_s
        skill_name = relative_to_working.gsub(".claude/skills/", "").gsub("/", "-")

        load_single_skill(dir, source_path, skill_name)
      end
    end

    # Get all loaded skills
    # @return [Array<Skill>]
    def all_skills
      @skills.values
    end

    # Get a skill by its identifier
    # @param identifier [String] Skill name or directory name
    # @return [Skill, nil]
    def [](identifier)
      @skills[identifier]
    end

    # Find a skill by its slash command
    # @param command [String] e.g., "/explain-code"
    # @return [Skill, nil]
    def find_by_command(command)
      @skills_by_command[command]
    end

    # Get skills that can be invoked by user
    # @return [Array<Skill>]
    def user_invocable_skills
      all_skills.select(&:user_invocable?)
    end

    # Get the count of loaded skills
    # @return [Integer]
    def count
      @skills.size
    end

    # Get loading errors
    # @return [Array<String>]
    def errors
      @errors.dup
    end

    # Get the source location for each loaded skill
    # @return [Hash{String => Symbol}] Map of skill identifier to source location
    def loaded_from
      @loaded_from.dup
    end

    # Clear loaded skills and errors
    def clear
      @skills.clear
      @skills_by_command.clear
      @errors.clear
    end

    # Create a new skill directory and SKILL.md file
    # @param name [String] Skill name (will be used for directory and slash command)
    # @param content [String] Skill content (SKILL.md body)
    # @param description [String] Skill description
    # @param location [Symbol] Where to create: :global or :project
    # @return [Skill] The created skill
    def create_skill(name, content, description = nil, location: :global)
      # Validate name
      unless name.match?(/^[a-z0-9][a-z0-9-]*$/)
        raise Clacky::Error,
          "Invalid skill name '#{name}'. Use lowercase letters, numbers, and hyphens only."
      end

      # Determine directory path
      skill_dir = case location
      when :global
        Pathname.new(ENV.fetch("HOME", "~")).join(".clacky", "skills", name)
      when :project
        Pathname.new(@working_dir).join(".clacky", "skills", name)
      else
        raise Clacky::Error, "Unknown skill location: #{location}"
      end

      # Create directory if it doesn't exist
      FileUtils.mkdir_p(skill_dir)

      # Build frontmatter
      frontmatter = { "name" => name, "description" => description }

      # Write SKILL.md
      skill_content = build_skill_content(frontmatter, content)
      skill_file = skill_dir.join("SKILL.md")
      skill_file.write(skill_content)

      # Load the newly created skill
      source_type = case location
      when :global then :global_clacky
      when :project then :project_clacky
      else :global_clacky
      end
      load_single_skill(skill_dir, skill_dir, name, source_type)
    end

    # Delete a skill
    # @param name [String] Skill name
    # @return [Boolean] True if deleted, false if not found
    def delete_skill(name)
      skill = @skills[name]
      return false unless skill

      # Remove from registry
      @skills.delete(name)
      @skills_by_command.delete(skill.slash_command)

      # Delete directory
      FileUtils.rm_rf(skill.directory)

      true
    end

    private

    def load_skills_from_directory(dir, source_type)
      return [] unless dir.exist?

      skills = []
      dir.children.select(&:directory?).each do |skill_dir|
        source_path = case source_type
        when :global_claude
          Pathname.new(ENV.fetch("HOME", "~")).join(".claude")
        when :global_clacky
          Pathname.new(ENV.fetch("HOME", "~")).join(".clacky")
        when :project_claude, :project_clacky
          Pathname.new(@working_dir)
        else
          skill_dir
        end

        skill_name = skill_dir.basename.to_s
        skill = load_single_skill(skill_dir, source_path, skill_name, source_type)
        skills << skill if skill
      end
      skills
    end

    def load_single_skill(skill_dir, source_path, skill_name, source_type)
      skill = Skill.new(skill_dir, source_path: source_path)

      # Check for duplicate names
      existing = @skills[skill.identifier]
      if existing
        # Skip duplicate (lower priority)
        existing_source = @loaded_from[skill.identifier]
        priority_order = [:global_claude, :global_clacky, :project_claude, :project_clacky]

        if priority_order.index(source_type) > priority_order.index(existing_source)
          # Replace with higher priority skill
          @skills.delete(existing.identifier)
          @skills_by_command.delete(existing.slash_command)
          @loaded_from.delete(existing.identifier)
        else
          @errors << "Skipping duplicate skill '#{skill.identifier}' at #{skill_dir}"
          return nil
        end
      end

      # Register skill
      @skills[skill.identifier] = skill
      @skills_by_command[skill.slash_command] = skill
      @loaded_from[skill.identifier] = source_type

      skill
    rescue Clacky::Error => e
      @errors << "Error loading skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    rescue StandardError => e
      @errors << "Unexpected error loading skill '#{skill_name}' from #{skill_dir}: #{e.message}"
      nil
    end

    def build_skill_content(frontmatter, content)
      yaml = frontmatter
        .reject { |_, v| v.nil? || v.to_s.empty? }
        .to_yaml(line_width: 80)

      "---\n#{yaml}---\n\n#{content}"
    end

    # Load default skills from gem's default_skills directory
    private def load_default_skills
      # Get the gem's lib directory
      gem_lib_dir = File.expand_path("../", __dir__)
      default_skills_dir = File.join(gem_lib_dir, "clacky", "default_skills")
      
      return unless Dir.exist?(default_skills_dir)
      
      # Load each skill directory
      Dir.glob(File.join(default_skills_dir, "*/SKILL.md")).each do |skill_file|
        skill_dir = File.dirname(skill_file)
        skill_name = File.basename(skill_dir)
        
        begin
          skill = Skill.new(Pathname.new(skill_dir))
          
          # Check for duplicates (higher priority skills override)
          if @skills.key?(skill.identifier)
            next  # Skip if already loaded from higher priority location
          end
          
          # Register skill
          @skills[skill.identifier] = skill
          @skills_by_command[skill.slash_command] = skill
          @loaded_from[skill.identifier] = :default
        rescue StandardError => e
          @errors << "Failed to load default skill #{skill_name}: #{e.message}"
        end
      end
    end
  end
end
