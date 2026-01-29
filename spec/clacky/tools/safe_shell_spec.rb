# frozen_string_literal: true

RSpec.describe Clacky::Tools::SafeShell do
  let(:tool) { described_class.new }

  describe "#execute" do
    context "output truncation" do
      it "does not truncate short output" do
        result = tool.execute(command: "echo 'Line 1\nLine 2\nLine 3'", max_output_lines: 10)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be false
        expect(result[:stdout].lines.count).to be <= 10
      end

      it "truncates long output when exceeding max_output_lines" do
        # Generate command that outputs many lines
        result = tool.execute(command: "seq 1 500", max_output_lines: 100)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be true
        # Should be truncated to ~100 lines plus truncation notice
        expect(result[:stdout].lines.count).to be <= 105
        expect(result[:stdout]).to include("Output truncated")
      end

      it "uses default max_output_lines of 1000 when not specified" do
        # Generate more than 1000 lines
        result = tool.execute(command: "seq 1 2000")

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be true
        # Should be truncated to ~1000 lines plus truncation notice
        expect(result[:stdout].lines.count).to be <= 1005
      end

      it "handles empty output" do
        result = tool.execute(command: "echo -n ''", max_output_lines: 10)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be false
      end
    end

    context "security features" do
      it "makes dangerous rm command safe" do
        result = tool.execute(command: "rm nonexistent_file.txt")

        # Should replace rm with mv to trash
        expect(result[:security_enhanced]).to be true
        expect(result[:safe_command]).to include("mv")
      end

      it "allows safe read-only commands without modification" do
        result = tool.execute(command: "ls -la")

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:security_enhanced]).to be_falsy
      end
    end
  end

  describe ".command_safe_for_auto_execution?" do
    it "returns true for safe read-only commands" do
      expect(described_class.command_safe_for_auto_execution?("ls -la")).to be true
      expect(described_class.command_safe_for_auto_execution?("pwd")).to be true
      expect(described_class.command_safe_for_auto_execution?("echo hello")).to be true
    end

    it "returns false for dangerous commands" do
      expect(described_class.command_safe_for_auto_execution?("sudo apt-get install")).to be false
    end
  end

  describe "#format_call" do
    it "formats command for display" do
      formatted = tool.format_call({ command: "ls -la" })

      expect(formatted).to include("safe_shell")
      expect(formatted).to include("ls -la")
    end

    it "truncates long commands" do
      long_command = "a" * 200
      formatted = tool.format_call({ command: long_command })

      expect(formatted.length).to be < long_command.length + 20
      expect(formatted).to include("...")
    end
  end

  describe "#format_result" do
    it "shows success with line count" do
      result = { exit_code: 0, stdout: "line1\nline2\nline3\n", stderr: "" }
      formatted = tool.format_result(result)

      expect(formatted).to include("✓")
      expect(formatted).to include("lines")
    end

    it "shows security enhancement indicator" do
      result = { exit_code: 0, stdout: "output", stderr: "", security_enhanced: true }
      formatted = tool.format_result(result)

      expect(formatted).to include("🔒")
    end

    it "shows error for failed commands" do
      result = { exit_code: 1, stdout: "", stderr: "Error message" }
      formatted = tool.format_result(result)

      expect(formatted).to include("✗")
      expect(formatted).to include("Exit 1")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("safe_shell")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("command")
      expect(definition[:function][:parameters][:properties]).to have_key(:timeout)
      expect(definition[:function][:parameters][:properties]).to have_key(:max_output_lines)
    end
  end

  describe "timeout behavior" do
    it "uses provided timeout as hard_timeout" do
      # Test that timeout parameter is properly used
      result = tool.execute(command: "echo 'test'", timeout: 30)
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
    end

    it "auto-detects timeout for slow commands when not specified" do
      # Just verify it doesn't crash with auto-detection
      result = tool.execute(command: "echo 'bundle install simulation'")
      
      expect(result[:exit_code]).to eq(0)
    end

    it "auto-detects timeout for normal commands when not specified" do
      result = tool.execute(command: "echo 'normal command'")
      
      expect(result[:exit_code]).to eq(0)
    end

    it "extracts timeout from 'timeout N command' format" do
      result = tool.execute(command: "timeout 30 echo 'test'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
      # The actual command executed should be without the timeout prefix
      expect(result[:stdout]).to include("test")
    end

    it "extracts timeout from 'timeout Ns command' format with seconds suffix" do
      result = tool.execute(command: "timeout 45s echo 'hello'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "extracts timeout with signal option 'timeout -s SIGNAL N command'" do
      result = tool.execute(command: "timeout -s KILL 60 echo 'world'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("world")
    end

    it "prefers explicit timeout parameter over extracted timeout" do
      # When both are provided, explicit parameter should win
      result = tool.execute(command: "timeout 10 echo 'test'", timeout: 99)
      
      expect(result[:exit_code]).to eq(0)
      # We can't directly test which timeout was used, but we verify it executes
    end
  end

    it "extracts timeout from 'cd xxx && timeout N command' format" do
      result = tool.execute(command: "cd /tmp && timeout 30 echo 'test'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
      expect(result[:stdout]).to include("test")
    end

    it "extracts timeout from 'export VAR=val && timeout N command' format" do
      result = tool.execute(command: "export TEST=value && timeout 45 echo 'hello'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "extracts timeout from 'prefix; timeout N command' format with semicolon" do
      result = tool.execute(command: "cd /tmp; timeout 60 echo 'world'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("world")
    end

    it "handles complex compound commands with timeout" do
      result = tool.execute(command: "cd spec && timeout 30s ls -la")
      
      expect(result[:exit_code]).to eq(0)
      # Should execute in spec directory
    end
end

