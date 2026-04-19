# frozen_string_literal: true

module Clacky
  class Agent
    # Scenario 2: Reflect on skill execution and suggest improvements.
    #
    # After a skill completes, inject a system prompt asking the LLM to analyze:
    #   - Were instructions clear enough?
    #   - Any missing edge cases?
    #   - Any improvements needed?
    #
    # If the LLM identifies concrete improvements, it can invoke skill-creator
    # to update the skill.
    module SkillReflector
      # Minimum iterations for a skill execution to warrant reflection
      MIN_SKILL_ITERATIONS = 2

      # Check if we should reflect on the skill that just executed
      # Called from SkillEvolution#run_skill_evolution_hooks
      def maybe_reflect_on_skill
        return unless @skill_execution_context

        skill_name = @skill_execution_context[:skill_name]
        start_iteration = @skill_execution_context[:start_iteration]
        iterations = @iterations - start_iteration

        # Only reflect if the skill actually ran for a meaningful number of iterations
        return if iterations < MIN_SKILL_ITERATIONS

        inject_skill_reflection_prompt(skill_name, iterations)

        # Clear the context so we don't reflect again
        @skill_execution_context = nil
      end

      # Inject reflection prompt into history as a system message
      # The LLM will respond in the next user interaction (non-blocking)
      #
      # @param skill_name [String] Identifier of the skill that was executed
      # @param iterations [Integer] Number of iterations the skill ran for
      private def inject_skill_reflection_prompt(skill_name, iterations)
        @history.append({
          role: "user",
          content: build_skill_reflection_prompt(skill_name, iterations),
          system_injected: true,
          skill_reflection: true
        })

        @ui&.show_info("Reflecting on skill execution: #{skill_name}")
      end

      # Build the reflection prompt content
      # @param skill_name [String]
      # @param iterations [Integer]
      # @return [String]
      private def build_skill_reflection_prompt(skill_name, iterations)
        <<~PROMPT
          ═══════════════════════════════════════════════════════════════
          SKILL REFLECTION MODE
          ═══════════════════════════════════════════════════════════════
          You just executed the skill "#{skill_name}" over #{iterations} iterations.

          ## Quick Analysis

          Reflect on whether the skill could be improved:
          - Were the instructions clear enough?
          - Did you encounter any edge cases not covered?
          - Were there any steps that could be streamlined?
          - Is there missing context that would make it easier next time?
          - Did the skill produce the expected results?

          ## Decision

          If you identified **concrete, actionable improvements**:
            → Call invoke_skill("skill-creator", task: "Improve skill #{skill_name}: [describe specific improvements needed]")

          If the skill worked well as-is:
            → Respond briefly: "Skill #{skill_name} worked well, no improvements needed."

          ## Constraints

          - DO NOT spend more than 30 seconds on this reflection
          - Be specific and actionable in your improvement suggestions
          - Only suggest improvements that would make a meaningful difference
          - If you're unsure, err on the side of "no improvements needed"
        PROMPT
      end
    end
  end
end
