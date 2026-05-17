# frozen_string_literal: true

require "spec_helper"

# Focused tests for the Agent ↔ UI bridge that pushes background-task state
# to the WebUI. We don't drive a full Agent.run loop — instead we exercise
# the two private helpers (broadcast_background_tasks_snapshot,
# format_terminal_notification) directly via .send to keep the test fast
# and deterministic.
RSpec.describe "Agent background-task UI broadcasts" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(
      model: "claude-sonnet-4.5",
      api_key: "test-api-key",
      base_url: "https://api.anthropic.com"
    )
    c
  end

  let(:ui) do
    Class.new do
      attr_reader :bg_updates, :bg_notices
      def initialize
        @bg_updates = []
        @bg_notices = []
      end
      def update_background_tasks(running:, tasks:)
        @bg_updates << { running: running, tasks: tasks }
      end
      def show_background_task_notice(command:, task_id:, status:)
        @bg_notices << { command: command, task_id: task_id, status: status }
      end
      # No-op stubs for any other UI methods the agent might touch.
      def method_missing(*); end
      def respond_to_missing?(*); true; end
    end.new
  end

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.tmpdir,
      ui: ui,
      profile: "general",
      session_id: "sess-#{SecureRandom.hex(4)}",
      source: :manual
    )
  end

  describe "#broadcast_background_tasks_snapshot" do
    it "pushes current active tasks to the UI" do
      bg = agent.instance_variable_get(:@active_background_tasks)
      bg["task-1"] = { command: "rspec", started_at: Time.now.to_f - 10 }
      bg["task-2"] = { command: "npm run build", started_at: Time.now.to_f - 30 }

      agent.send(:broadcast_background_tasks_snapshot)

      expect(ui.bg_updates.size).to eq(1)
      upd = ui.bg_updates.first
      expect(upd[:running]).to eq(2)
      ids = upd[:tasks].map { |t| t[:task_id] }
      expect(ids).to contain_exactly("task-1", "task-2")
      task1 = upd[:tasks].find { |t| t[:task_id] == "task-1" }
      expect(task1[:command]).to eq("rspec")
      expect(task1[:elapsed]).to be >= 10
    end

    it "pushes an empty list when no tasks are running (hides badge)" do
      agent.send(:broadcast_background_tasks_snapshot)
      expect(ui.bg_updates.last[:running]).to eq(0)
      expect(ui.bg_updates.last[:tasks]).to eq([])
    end

    it "is silent when no UI is attached" do
      agent.instance_variable_set(:@ui, nil)
      expect { agent.send(:broadcast_background_tasks_snapshot) }.not_to raise_error
    end

    it "rescues UI exceptions without raising into the agent loop" do
      bad_ui = Object.new
      def bad_ui.update_background_tasks(**); raise "boom"; end
      agent.instance_variable_set(:@ui, bad_ui)
      expect {
        agent.send(:broadcast_background_tasks_snapshot)
      }.not_to raise_error
    end
  end

  describe "#format_terminal_notification (UI side effects)" do
    let(:task_id) { "abc123de-task-id" }

    before do
      bg = agent.instance_variable_get(:@active_background_tasks)
      bg[task_id] = { command: "npm run build", started_at: Time.now.to_f }
    end

    it "removes the completed task from active set and broadcasts snapshot" do
      result = {
        task_id: task_id,
        command: "npm run build",
        exit_code: 0,
        output: "ok"
      }
      agent.send(:format_terminal_notification, result)

      bg = agent.instance_variable_get(:@active_background_tasks)
      expect(bg).not_to have_key(task_id)
      # Snapshot pushed after removal — should now be empty.
      expect(ui.bg_updates.last[:running]).to eq(0)
    end

    it "emits a 'success' transition notice when exit_code is zero" do
      agent.send(:format_terminal_notification,
        task_id: task_id,
        command: "npm run build",
        exit_code: 0)

      expect(ui.bg_notices.size).to eq(1)
      n = ui.bg_notices.first
      expect(n[:command]).to eq("npm run build")
      expect(n[:task_id]).to eq("abc123de")          # short id
      expect(n[:status]).to eq("success")
    end

    it "emits a 'failed' transition notice on non-zero exit code" do
      agent.send(:format_terminal_notification,
        task_id: task_id,
        command: "make",
        exit_code: 1)
      expect(ui.bg_notices.first[:status]).to eq("failed")
    end

    it "emits a 'cancelled' transition notice when task was cancelled" do
      agent.send(:format_terminal_notification,
        task_id: task_id,
        command: "sleep 99",
        cancelled: true)
      expect(ui.bg_notices.first[:status]).to eq("cancelled")
    end

    it "emits an 'error' transition notice on harness error" do
      agent.send(:format_terminal_notification,
        task_id: task_id,
        command: "x",
        error: "watchdog timeout")
      expect(ui.bg_notices.first[:status]).to eq("error")
    end
  end
end
