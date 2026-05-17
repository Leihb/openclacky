# frozen_string_literal: true

require "securerandom"

module Clacky
  # BackgroundTaskRegistry tracks fire-and-forget tasks started by tools
  # (e.g. terminal fire_and_forget) and notifies the owning agent when
  # they complete.
  #
  # Flow:
  #   1. Tool (e.g. Terminal) calls create_task() → gets task_id
  #   2. Tool starts a watcher thread; when done calls complete(task_id, result)
  #   3. Agent, after seeing the tool's accepted response, registers a callback
  #      via register_callback(task_id:, agent:, &block)
  #   4. When the task completes, the callback is fired on a dedicated thread.
  #
  # Thread safety: all mutations go through a class-level Mutex.
  class BackgroundTaskRegistry
    @tasks     = {}
    @callbacks = {}
    @mutex     = Mutex.new

    class << self
      # Register a new background task. Called by the tool that starts it.
      # Returns the task_id.
      #
      # on_cancel: optional proc called when the task is cancelled. Receives
      #   the task struct. The proc is responsible for actually killing the
      #   underlying process/session.
      def create_task(type:, metadata: {}, on_cancel: nil)
        task_id = SecureRandom.uuid
        @mutex.synchronize do
          @tasks[task_id] = {
            id: task_id,
            type: type,
            status: "running",
            metadata: metadata,
            result: nil,
            created_at: Time.now,
            completed_at: nil,
            on_cancel: on_cancel
          }
        end
        task_id
      end

      # Register a completion callback for a task. Called by the agent after
      # it sees the tool accepted the background request.
      #
      # Race-safe: if the task already finished between create_task and
      # register_callback (rare but possible — e.g. a task that completes
      # within milliseconds of the 2s startup window), we fire the callback
      # immediately on a fresh thread instead of dropping the notification.
      def register_callback(task_id:, agent:, &block)
        fire_immediately = nil

        @mutex.synchronize do
          task = @tasks[task_id]
          return false unless task

          if task[:status] == "completed" || task[:status] == "cancelled"
            # Task already finished — capture its result and fire after
            # releasing the lock to avoid holding it across user code.
            fire_immediately = task[:result] || {
              cancelled: task[:status] == "cancelled",
              output: task[:status] == "cancelled" ? "Task was cancelled by user." : "",
              exit_code: nil,
              state: task[:status]
            }
          else
            @callbacks[task_id] = {
              agent: agent,
              callback: block,
              registered_at: Time.now
            }
          end
        end

        if fire_immediately
          Thread.new do
            Thread.current.name = "bg-task-notify-late-#{task_id[0, 8]}"
            begin
              block.call(fire_immediately)
            rescue => e
              Clacky::Logger.error("background_task_callback_error",
                task_id: task_id,
                agent_session: agent&.session_id,
                error: e
              )
            end
          end
        end

        true
      end

      # Cancel a running background task. Calls the on_cancel proc if present,
      # then marks the task as completed with a cancellation result.
      # Returns true if cancelled, false if already completed/unknown.
      def cancel(task_id)
        task = nil
        handler = nil

        @mutex.synchronize do
          task = @tasks[task_id]
          return false unless task
          return false if task[:status] == "completed" || task[:status] == "cancelled"

          task[:status] = "cancelled"
          handler = @callbacks.delete(task_id)
        end

        # Invoke the tool's cancellation hook (kill process, cleanup, etc.)
        begin
          task[:on_cancel]&.call(task)
        rescue => e
          Clacky::Logger.error("background_task_cancel_hook_error",
            task_id: task_id,
            error: e
          )
        end

        # Fire completion callback with cancellation result
        if handler
          Thread.new do
            Thread.current.name = "bg-task-cancel-#{task_id[0, 8]}"
            begin
              handler[:callback].call({
                cancelled: true,
                output: "Task was cancelled by user.",
                exit_code: nil,
                state: "cancelled"
              })
            rescue => e
              Clacky::Logger.error("background_task_callback_error",
                task_id: task_id,
                agent_session: handler[:agent]&.session_id,
                error: e
              )
            end
          end
        end

        true
      end

      # Mark a task as completed and fire its callback if one was registered.
      # Called by the tool's watcher thread.
      def complete(task_id, result)
        handler = nil

        @mutex.synchronize do
          task = @tasks[task_id]
          return unless task
          # If already cancelled, don't overwrite
          return if task[:status] == "cancelled"

          task[:status] = "completed"
          task[:result] = result
          task[:completed_at] = Time.now

          handler = @callbacks.delete(task_id)
        end

        return unless handler

        # Fire callback on a fresh thread so the watcher never blocks on
        # agent.run() which may take arbitrarily long.
        Thread.new do
          Thread.current.name = "bg-task-notify-#{task_id[0, 8]}"
          begin
            handler[:callback].call(result)
          rescue => e
            Clacky::Logger.error("background_task_callback_error",
              task_id: task_id,
              agent_session: handler[:agent]&.session_id,
              error: e
            )
          end
        end
      end

      # List running tasks for a given agent session.
      def list_running(agent_session_id: nil)
        @mutex.synchronize do
          tasks = @tasks.values.select { |t| t[:status] == "running" }
          tasks = tasks.select { |t| t[:metadata][:agent_session_id] == agent_session_id } if agent_session_id
          tasks.map do |t|
            {
              task_id: t[:id],
              type: t[:type],
              command: t[:metadata][:command],
              started_at: t[:created_at]&.iso8601
            }
          end
        end
      end

      # Peek at a task's current state (non-mutating).
      def get(task_id)
        @mutex.synchronize { @tasks[task_id]&.dup }
      end

      # Forget a completed task to free memory. Best-effort.
      def forget(task_id)
        @mutex.synchronize do
          @tasks.delete(task_id)
          @callbacks.delete(task_id)
        end
      end

      # Forget stale completed tasks older than max_age seconds.
      # When agent_session_id is given, only that session's tasks are pruned —
      # this keeps long-lived sessions from racing each other in the shared
      # registry (server mode runs many agents in one process).
      def prune_completed(max_age: 3600, agent_session_id: nil)
        cutoff = Time.now - max_age
        @mutex.synchronize do
          @tasks.delete_if do |_id, task|
            next false unless task[:status] == "completed"
            next false unless task[:completed_at] && task[:completed_at] < cutoff
            next false if agent_session_id && task[:metadata][:agent_session_id] != agent_session_id
            true
          end
        end
      end

      # Test helper: clear everything without firing callbacks.
      def reset!
        @mutex.synchronize do
          @tasks.clear
          @callbacks.clear
        end
      end
    end
  end
end
