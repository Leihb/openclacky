# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Agent::MemoryUpdater do
  # Create a minimal test class that includes the module
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::MemoryUpdater

      attr_accessor :iterations, :messages, :task_start_iterations

      def initialize
        @iterations = 0
        @task_start_iterations = 0
        @messages = []
      end

      # Stub config with memory update enabled
      def config
        double("config", memory_update_enabled: true)
      end
      alias_method :@config, :config

      def ui
        nil
      end

      def think; end
      def act(_); end
      def observe(_, _); end
    end
  end

  let(:agent) { agent_class.new }

  describe "#should_update_memory?" do
    context "when iterations are below threshold" do
      it "returns false" do
        agent.iterations = 3
        agent.task_start_iterations = 0
        expect(agent.should_update_memory?).to be false
      end
    end

    context "when iterations meet threshold" do
      it "returns true" do
        agent.iterations = 10
        agent.task_start_iterations = 0
        expect(agent.should_update_memory?).to be true
      end
    end

    context "when task iterations are below threshold even if total is high" do
      it "returns false" do
        agent.iterations = 100
        agent.task_start_iterations = 97  # only 3 task iterations
        expect(agent.should_update_memory?).to be false
      end
    end
  end

  describe "MEMORIES_DIR" do
    it "points to ~/.clacky/memories" do
      expect(Clacky::Agent::MemoryUpdater::MEMORIES_DIR).to eq(
        File.expand_path("~/.clacky/memories")
      )
    end
  end

  describe "MEMORY_UPDATE_PROMPT" do
    it "includes key instructions" do
      prompt = Clacky::Agent::MemoryUpdater::MEMORY_UPDATE_PROMPT
      expect(prompt).to include("MEMORY UPDATE MODE")
      expect(prompt).to include("~/.clacky/memories/")
      expect(prompt).to include("4000 characters")
      expect(prompt).to include("updated_at")
    end
  end
end
