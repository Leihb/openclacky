# frozen_string_literal: true

module Clacky
  class Agent
    # Unified entry point for skill self-evolution system.
    # Coordinates two scenarios:
    #   1. Auto-create new skills from complex task patterns
    #   2. Reflect on executed skills and suggest improvements
    #
    # Triggered at the end of Agent#run (post-run hooks), only for main agents.
    module SkillEvolution
      # Main entry point - runs all skill evolution checks
      # Called from Agent#run after the main loop completes
      def run_skill_evolution_hooks
        return unless skill_evolution_enabled?
        return if @is_subagent

        # Scenario 2: Reflect on executed skill (if one just ran)
        maybe_reflect_on_skill if @skill_execution_context

        # Scenario 1: Auto-create new skill from complex task
        maybe_create_skill_from_task
      end

      # Check if skill evolution is enabled in config
      # @return [Boolean]
      private def skill_evolution_enabled?
        # Default to true if not explicitly disabled
        return true unless @config.respond_to?(:skill_evolution)

        config = @config.skill_evolution
        return true if config.nil?

        config[:enabled] != false
      end

      # Get skill evolution configuration hash
      # @return [Hash]
      private def skill_evolution_config
        return {} unless @config.respond_to?(:skill_evolution)

        @config.skill_evolution || {}
      end
    end
  end
end
