# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe Clacky::SkillLoader do
  let(:temp_dir) { Dir.mktmpdir }
  let(:working_dir) { temp_dir }

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe "#initialize" do
    it "initializes with working directory" do
      loader = described_class.new(working_dir)

      expect(loader).to be_a(described_class)
    end

    it "uses current directory when no working_dir given" do
      original_dir = Dir.pwd
      loader = described_class.new
      expect(loader).to be_a(described_class)
    ensure
      Dir.chdir(original_dir)
    end
  end

  describe "#load_all" do
    context "with no skills directories" do
      it "returns only virtual skills" do
        loader = described_class.new(working_dir)
        skills = loader.load_all

        expect(skills.size).to eq(1)
        expect(skills.first.identifier).to eq("skill-add")
      end
    end

    context "with skills in project .clacky/skills/" do
      it "loads skills from .clacky/skills/" do
        # Create skill in .clacky/skills/
        skills_dir = File.join(working_dir, ".clacky", "skills")
        FileUtils.mkdir_p(skills_dir)

        skill_dir = File.join(skills_dir, "project-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: project-skill
          description: A project skill
          ---
          Project skill content.
        CONTENT

        loader = described_class.new(working_dir)
        skills = loader.load_all

        skill_identifiers = skills.map(&:identifier)
        expect(skill_identifiers).to include("project-skill")
      end
    end

    context "with skills in project .claude/skills/" do
      it "loads skills from .claude/skills/" do
        # Create skill in .claude/skills/
        skills_dir = File.join(working_dir, ".claude", "skills")
        FileUtils.mkdir_p(skills_dir)

        skill_dir = File.join(skills_dir, "claude-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: claude-skill
          description: A Claude-compatible skill
          ---
          Claude skill content.
        CONTENT

        loader = described_class.new(working_dir)
        skills = loader.load_all

        skill_identifiers = skills.map(&:identifier)
        expect(skill_identifiers).to include("claude-skill")
      end
    end

    context "with skills in global .clacky/skills/" do
      it "loads skills from ~/.clacky/skills/" do
        global_dir = File.join(ENV.fetch("HOME", "~"), ".clacky", "skills")
        FileUtils.mkdir_p(global_dir)

        skill_dir = File.join(global_dir, "global-clacky-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: global-clacky-skill
          description: A global clacky skill
          ---
          Global clacky content.
        CONTENT

        begin
          loader = described_class.new(working_dir)
          skills = loader.load_all

          skill_ids = skills.map(&:identifier)
          expect(skill_ids).to include("global-clacky-skill")
        ensure
          FileUtils.rm_rf(global_dir)
        end
      end
    end

    context "with skills in global .claude/skills/" do
      it "loads skills from ~/.claude/skills/" do
        global_dir = File.join(ENV.fetch("HOME", "~"), ".claude", "skills")
        FileUtils.mkdir_p(global_dir)

        skill_dir = File.join(global_dir, "global-claude-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: global-claude-skill
          description: A global Claude skill
          ---
          Global Claude content.
        CONTENT

        begin
          loader = described_class.new(working_dir)
          skills = loader.load_all

          skill_ids = skills.map(&:identifier)
          expect(skill_ids).to include("global-claude-skill")
        ensure
          FileUtils.rm_rf(global_dir)
        end
      end
    end

    context "with duplicate skills" do
      it "uses higher priority skill when duplicates exist" do
        # Create same skill in both .claude and .clacky
        claude_dir = File.join(working_dir, ".claude", "skills", "duplicate-skill")
        FileUtils.mkdir_p(claude_dir)
        File.write(File.join(claude_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: duplicate-skill
          description: From .claude (lower priority)
          ---
          Claude version content.
        CONTENT

        clacky_dir = File.join(working_dir, ".clacky", "skills", "duplicate-skill")
        FileUtils.mkdir_p(clacky_dir)
        File.write(File.join(clacky_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: duplicate-skill
          description: From .clacky (higher priority)
          ---
          Clacky version content.
        CONTENT

        loader = described_class.new(working_dir)
        skills = loader.load_all

        duplicate_skill = skills.find { |s| s.identifier == "duplicate-skill" }
        expect(duplicate_skill.context_description).to eq("From .clacky (higher priority)")
      end

      it "logs warning for skipped duplicates" do
        # Create same skill in both global and project locations
        # Global .claude is loaded first (lower priority), project .clacky is loaded last (higher priority)
        # So global .claude skill should be skipped and generate a warning
        global_claude_dir = File.join(ENV.fetch("HOME", "~"), ".claude", "skills", "warn-skill")
        FileUtils.mkdir_p(global_claude_dir)
        File.write(File.join(global_claude_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: warn-skill
          description: Lower priority global version
          ---
          Lower priority content.
        CONTENT

        project_clacky_dir = File.join(working_dir, ".clacky", "skills", "warn-skill")
        FileUtils.mkdir_p(project_clacky_dir)
        File.write(File.join(project_clacky_dir, "SKILL.md"), <<~CONTENT)
          ---
          name: warn-skill
          description: Higher priority project version
          ---
          Higher priority content.
        CONTENT

        begin
          loader = described_class.new(working_dir)
          loader.load_all

          # Global .claude (lower priority) was loaded first, project .clacky (higher priority) last
          # When project .clacky skill is loaded, it should replace global .claude's skill
          # No warning should be generated because higher priority replaces lower
          expect(loader.errors).to be_empty
          warn_skill = loader.all_skills.find { |s| s.identifier == "warn-skill" }
          expect(warn_skill).not_to be_nil
          expect(warn_skill.context_description).to eq("Higher priority project version")
        ensure
          FileUtils.rm_rf(global_claude_dir)
        end
      end
    end

    context "with multiple skills" do
      it "loads multiple skills from same directory" do
        skills_dir = File.join(working_dir, ".clacky", "skills")
        FileUtils.mkdir_p(skills_dir)

        skill_names = %w[skill-one skill-two skill-three]
        skill_names.each do |name|
          skill_dir = File.join(skills_dir, name)
          FileUtils.mkdir_p(skill_dir)
          File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
            ---
            name: #{name}
            description: Skill #{name}
            ---
            Content for #{name}.
          CONTENT
        end

        loader = described_class.new(working_dir)
        skills = loader.load_all

        skill_identifiers = skills.map(&:identifier)
        expect(skill_identifiers).to include(*skill_names)
      end
    end
  end

  describe "#find_by_command" do
    it "finds skill by slash command" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "find-me")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: find-me
        description: Find this skill
        ---
        Content here.
      CONTENT

      loader = described_class.new(working_dir)
      loader.load_all

      skill = loader.find_by_command("/find-me")

      expect(skill).not_to be_nil
      expect(skill.identifier).to eq("find-me")
    end

    it "returns nil for non-existent command" do
      loader = described_class.new(working_dir)
      loader.load_all

      skill = loader.find_by_command("/nonexistent")

      expect(skill).to be_nil
    end
  end

  describe "#errors" do
    it "returns empty array when no errors" do
      loader = described_class.new(working_dir)
      loader.load_all

      expect(loader.errors).to be_empty
    end

    it "collects errors from invalid skills" do
      skills_dir = File.join(working_dir, ".clacky", "skills")
      FileUtils.mkdir_p(skills_dir)

      skill_dir = File.join(skills_dir, "invalid-skill")
      FileUtils.mkdir_p(skill_dir)
      # Create invalid skill with unclosed frontmatter
      File.write(File.join(skill_dir, "SKILL.md"), <<~CONTENT)
        ---
        name: invalid-skill
        description: Invalid skill
        This frontmatter is not closed properly
      CONTENT

      loader = described_class.new(working_dir)
      loader.load_all

      expect(loader.errors).not_to be_empty
      expect(loader.errors.first).to include("invalid-skill")
    end
  end

  describe "#create_skill" do
    context "with global location" do
      it "creates skill in ~/.clacky/skills/" do
        global_dir = File.join(ENV.fetch("HOME", "~"), ".clacky", "skills")

        begin
          loader = described_class.new(working_dir)
          skill = loader.create_skill("new-global-skill", "New skill content", "A new skill", location: :global)

          expect(skill.identifier).to eq("new-global-skill")
          expect(skill.content).to include("New skill content")
          expect(skill.context_description).to eq("A new skill")

          expect(File.exist?(File.join(global_dir, "new-global-skill", "SKILL.md"))).to be true
        ensure
          FileUtils.rm_rf(global_dir)
        end
      end
    end

    context "with project location" do
      it "creates skill in project .clacky/skills/" do
        loader = described_class.new(working_dir)
        skill = loader.create_skill("new-project-skill", "Project skill content", "A project skill", location: :project)

        expect(skill.identifier).to eq("new-project-skill")
        expect(skill.content).to include("Project skill content")

        project_skills_dir = File.join(working_dir, ".clacky", "skills")
        expect(File.exist?(File.join(project_skills_dir, "new-project-skill", "SKILL.md"))).to be true
      end
    end

    it "validates skill name format" do
      loader = described_class.new(working_dir)

      expect do
        loader.create_skill("Invalid Name!", "content", "desc")
      end.to raise_error(Clacky::Error, /Invalid skill name/)
    end
  end

  describe "#delete_skill" do
    it "deletes an existing skill" do
      # First create a skill
      loader = described_class.new(working_dir)
      loader.create_skill("to-delete", "Content to delete", "Delete me", location: :project)

      skill_dir = File.join(working_dir, ".clacky", "skills", "to-delete")
      expect(File.exist?(skill_dir)).to be true

      # Delete it
      loader.delete_skill("to-delete")

      expect(File.exist?(skill_dir)).to be false
    end

    it "does not error for non-existent skill" do
      loader = described_class.new(working_dir)

      expect do
        loader.delete_skill("nonexistent-skill")
      end.not_to raise_error
    end
  end
end
