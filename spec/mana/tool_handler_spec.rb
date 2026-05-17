# frozen_string_literal: true

require "spec_helper"

# ToolHandler is mixed into Engine. We instantiate Engine to exercise it.
RSpec.describe Mana::ToolHandler do
  let(:bind) { Object.new.instance_eval { x = 1; binding } }
  let(:engine) { Mana::Engine.new(bind) }

  describe "error return contract" do
    it "uses the standardized 'error: ' prefix for unknown tools" do
      result = engine.send(:handle_effect, { name: "nonexistent_tool_xyz", input: {} })
      expect(result).to start_with(Mana::ToolHandler::TOOL_ERROR_PREFIX)
      expect(result).to include("unknown tool")
    end

    it "uses the standardized 'error: ' prefix when a handler raises" do
      # write_var with a binding that doesn't allow that var name → raises
      # internally, gets caught and stringified.
      result = engine.send(:handle_effect, {
        name: "call_func",
        input: { "name" => "absolutely_no_such_method_anywhere" }
      })
      expect(result).to start_with(Mana::ToolHandler::TOOL_ERROR_PREFIX)
      expect(result).to include("NameError")
    end

    it "propagates LLMError from the 'error' tool (does not stringify)" do
      expect {
        engine.send(:handle_effect, { name: "error", input: { "message" => "boom" } })
      }.to raise_error(Mana::LLMError, "boom")
    end

    it "uses the standardized 'ok: ' prefix for write_var success" do
      engine.instance_variable_set(:@written_vars, {})
      result = engine.send(:handle_effect, {
        name: "write_var",
        input: { "name" => "x", "value" => 42 }
      })
      expect(result).to start_with(Mana::ToolHandler::TOOL_OK_PREFIX)
    end
  end

  describe ".tool_error helper" do
    it "formats messages with the canonical prefix" do
      expect(engine.send(:tool_error, "bad input")).to eq("error: bad input")
    end
  end
end
