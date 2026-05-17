# frozen_string_literal: true

require "spec_helper"

# Multi-session isolation tests for the BackgroundTaskRegistry and the
# terminal tool's interaction with it. The registry is a process-level
# singleton — when several agent sessions run in the same process (which
# is exactly the server mode), each session must only see and be able to
# act on its own tasks.
RSpec.describe "BackgroundTaskRegistry multi-session isolation" do
  before { Clacky::BackgroundTaskRegistry.reset! }
  after  { Clacky::BackgroundTaskRegistry.reset! }

  describe ".list_running with agent_session_id filter" do
    it "returns only tasks belonging to the requested session" do
      id_a = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal",
        metadata: { command: "sleep 30", agent_session_id: "sess-A" }
      )
      id_b = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal",
        metadata: { command: "sleep 60", agent_session_id: "sess-B" }
      )

      running_a = Clacky::BackgroundTaskRegistry.list_running(agent_session_id: "sess-A")
      running_b = Clacky::BackgroundTaskRegistry.list_running(agent_session_id: "sess-B")

      expect(running_a.map { |t| t[:task_id] }).to contain_exactly(id_a)
      expect(running_b.map { |t| t[:task_id] }).to contain_exactly(id_b)
    end

    it "returns all running tasks when no agent_session_id is given" do
      Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-A" }
      )
      Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-B" }
      )

      expect(Clacky::BackgroundTaskRegistry.list_running.size).to eq(2)
    end
  end

  describe "callback routing" do
    it "fires each session's callback only with its own task result" do
      received_a = Queue.new
      received_b = Queue.new

      id_a = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-A" }
      )
      id_b = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-B" }
      )

      Clacky::BackgroundTaskRegistry.register_callback(task_id: id_a, agent: nil) do |r|
        received_a << r
      end
      Clacky::BackgroundTaskRegistry.register_callback(task_id: id_b, agent: nil) do |r|
        received_b << r
      end

      Clacky::BackgroundTaskRegistry.complete(id_b, { exit_code: 0, output: "B done", task_id: id_b })
      Clacky::BackgroundTaskRegistry.complete(id_a, { exit_code: 1, output: "A done", task_id: id_a })

      result_a = received_a.pop
      result_b = received_b.pop

      expect(result_a[:output]).to eq("A done")
      expect(result_a[:exit_code]).to eq(1)
      expect(result_b[:output]).to eq("B done")
      expect(result_b[:exit_code]).to eq(0)
    end
  end

  describe ".prune_completed scope" do
    it "with agent_session_id, only prunes that session's completed tasks" do
      id_a = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-A" }
      )
      id_b = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-B" }
      )

      Clacky::BackgroundTaskRegistry.complete(id_a, { exit_code: 0 })
      Clacky::BackgroundTaskRegistry.complete(id_b, { exit_code: 0 })

      Clacky::BackgroundTaskRegistry.instance_variable_get(:@tasks).each_value do |t|
        t[:completed_at] = Time.now - 7200
      end

      Clacky::BackgroundTaskRegistry.prune_completed(max_age: 3600, agent_session_id: "sess-A")

      expect(Clacky::BackgroundTaskRegistry.get(id_a)).to be_nil
      expect(Clacky::BackgroundTaskRegistry.get(id_b)).not_to be_nil
    end

    it "without agent_session_id, prunes globally as before" do
      id_a = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-A" }
      )
      id_b = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-B" }
      )

      Clacky::BackgroundTaskRegistry.complete(id_a, { exit_code: 0 })
      Clacky::BackgroundTaskRegistry.complete(id_b, { exit_code: 0 })

      Clacky::BackgroundTaskRegistry.instance_variable_get(:@tasks).each_value do |t|
        t[:completed_at] = Time.now - 7200
      end

      Clacky::BackgroundTaskRegistry.prune_completed(max_age: 3600)

      expect(Clacky::BackgroundTaskRegistry.get(id_a)).to be_nil
      expect(Clacky::BackgroundTaskRegistry.get(id_b)).to be_nil
    end
  end

  describe "concurrent cancel does not leak across sessions" do
    it "cancelling one session's task leaves the other's callback intact" do
      received_a = Queue.new
      received_b = Queue.new

      id_a = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-A" }
      )
      id_b = Clacky::BackgroundTaskRegistry.create_task(
        type: "terminal", metadata: { agent_session_id: "sess-B" }
      )

      Clacky::BackgroundTaskRegistry.register_callback(task_id: id_a, agent: nil) { |r| received_a << r }
      Clacky::BackgroundTaskRegistry.register_callback(task_id: id_b, agent: nil) { |r| received_b << r }

      Clacky::BackgroundTaskRegistry.cancel(id_a)
      Clacky::BackgroundTaskRegistry.complete(id_b, { exit_code: 0, output: "B finished" })

      ra = received_a.pop
      rb = received_b.pop

      expect(ra[:cancelled]).to be(true)
      expect(rb[:output]).to eq("B finished")
      expect(rb[:cancelled]).to be_nil
    end
  end
end

RSpec.describe "Terminal tool stamps agent_session_id on background tasks" do
  before { Clacky::BackgroundTaskRegistry.reset! }
  after  { Clacky::BackgroundTaskRegistry.reset! }

  def stub_background_path(tool, session_id:)
    fake_session = double("session", id: session_id, pid: 12345,
      writer: double(close: nil), reader: double(close: nil), log_io: double(close: nil))
    allow(tool).to receive(:spawn_dedicated_session).and_return(fake_session)
    allow(tool).to receive(:write_user_command)
    allow(tool).to receive(:wait_and_package).and_return(
      { session_id: session_id, state: "background", output: "", bytes_read: 0 }
    )
    allow(tool).to receive(:start_background_watcher)
    fake_session
  end

  it "passes agent_session_id from the tool to BackgroundTaskRegistry metadata" do
    tool = Clacky::Tools::Terminal.new(agent_session_id: "sess-X")
    stub_background_path(tool, session_id: 42)

    captured = nil
    allow(Clacky::BackgroundTaskRegistry).to receive(:create_task).and_wrap_original do |orig, **kwargs|
      captured = kwargs
      orig.call(**kwargs)
    end

    tool.execute(command: "sleep 30", run_in_background: true)

    expect(captured).not_to be_nil
    expect(captured[:metadata][:agent_session_id]).to eq("sess-X")
  end

  it "with two Terminal tools in the same process, list_running cleanly partitions" do
    tool_a = Clacky::Tools::Terminal.new(agent_session_id: "sess-A")
    tool_b = Clacky::Tools::Terminal.new(agent_session_id: "sess-B")

    stub_background_path(tool_a, session_id: 42)
    stub_background_path(tool_b, session_id: 43)

    tool_a.execute(command: "sleep 30", run_in_background: true)
    tool_b.execute(command: "sleep 60", run_in_background: true)

    a_running = Clacky::BackgroundTaskRegistry.list_running(agent_session_id: "sess-A")
    b_running = Clacky::BackgroundTaskRegistry.list_running(agent_session_id: "sess-B")

    expect(a_running.size).to eq(1)
    expect(a_running.first[:command]).to eq("sleep 30")
    expect(b_running.size).to eq(1)
    expect(b_running.first[:command]).to eq("sleep 60")
  end

  it "nil agent_session_id (CLI/standalone) still works and produces nil metadata" do
    tool = Clacky::Tools::Terminal.new
    stub_background_path(tool, session_id: 44)

    captured = nil
    allow(Clacky::BackgroundTaskRegistry).to receive(:create_task).and_wrap_original do |orig, **kwargs|
      captured = kwargs
      orig.call(**kwargs)
    end

    tool.execute(command: "sleep 5", run_in_background: true)

    expect(captured[:metadata]).to have_key(:agent_session_id)
    expect(captured[:metadata][:agent_session_id]).to be_nil
  end
end
