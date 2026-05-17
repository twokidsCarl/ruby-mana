# frozen_string_literal: true

require "spec_helper"

# Coverage for the medium-batch fixes:
# - handle_effect error path branches
# - binding_helpers with unusual identifier shapes

RSpec.describe "Mana::ToolHandler#handle_effect error paths" do
  let(:bind) { Object.new.instance_eval { x = 1; binding } }
  let(:engine) { Mana::Engine.new(bind) }

  it "stringifies a NameError from a registered tool handler" do
    Mana.register_tool({ name: "bad_tool", description: "", input_schema: {} }) do |_|
      raise NameError, "this is unusable"
    end
    result = engine.send(:handle_effect, { name: "bad_tool", input: {} })
    expect(result).to start_with("error: ")
    expect(result).to include("NameError")
    expect(result).to include("unusable")
  end

  it "stringifies a SyntaxError raised from inside a tool" do
    result = engine.send(:handle_effect, {
      name: "eval", input: { "code" => "def end" }
    })
    expect(result).to start_with("error: ")
    expect(result).to include("SyntaxError")
  end

  it "stringifies a NoMethodError (e.g. from chained call_func on nil)" do
    bind.local_variable_set(:y, nil)
    result = engine.send(:handle_effect, {
      name: "call_func", input: { "name" => "y.upcase" }
    })
    expect(result).to start_with("error: ")
  end

  it "stringifies TypeError" do
    result = engine.send(:handle_effect, {
      name: "eval", input: { "code" => "1 + 'a'" }
    })
    expect(result).to start_with("error: ")
    expect(result).to include("TypeError")
  end

  it "uses the standardized 'error: ' prefix for all string error returns" do
    # Documents the contract: every recoverable failure returns a string
    # starting with "error: " so claw's chat-history rendering can detect
    # tool errors uniformly. The immediate-batch PR factors this into a
    # TOOL_ERROR_PREFIX constant; this test stays loose to also pass before
    # that PR lands.
    bad_inputs = [
      { name: "nonexistent_tool", input: {} },
      { name: "eval", input: { "code" => "definitely_not_defined_var_xyz" } },
      { name: "call_func", input: { "name" => "no_such_method_zzz" } }
    ]
    bad_inputs.each do |tool_use|
      result = engine.send(:handle_effect, tool_use)
      expect(result).to start_with("error: "),
        "Expected '#{tool_use[:name]}' error to start with 'error: ', got: #{result.inspect}"
    end
  end

  it "does not stringify Mana::LLMError (re-raises for engine loop termination)" do
    expect {
      engine.send(:handle_effect, {
        name: "error", input: { "message" => "stop the loop" }
      })
    }.to raise_error(Mana::LLMError, "stop the loop")
  end
end

RSpec.describe "Mana::BindingHelpers identifier edge cases" do
  let(:engine) do
    b = Object.new.instance_eval { binding }
    Mana::Engine.new(b)
  end

  describe "#validate_name!" do
    it "accepts normal Ruby identifiers" do
      %w[foo snake_case with_digits1 _internal CamelCase].each do |ok|
        expect { engine.send(:validate_name!, ok) }.not_to raise_error,
          "expected #{ok.inspect} to be accepted"
      end
    end

    # The regex `\A[A-Za-z_][A-Za-z0-9_]*\z` deliberately rejects shell
    # metacharacters, predicate/bang suffixes, whitespace, and non-ASCII
    # letters. Document the actual contract here so future relaxations are
    # intentional rather than accidental.
    it "rejects names with shell metacharacters" do
      ["foo;bar", "foo|bar", "foo`bar`", "foo$(x)", "foo&&bar"].each do |bad|
        expect { engine.send(:validate_name!, bad) }
          .to raise_error(Mana::Error),
          "expected #{bad.inspect} to be rejected"
      end
    end

    it "rejects names with whitespace" do
      ["foo bar", " foo", "foo\n", "foo\t"].each do |bad|
        expect { engine.send(:validate_name!, bad) }.to raise_error(Mana::Error)
      end
    end

    it "rejects empty input" do
      expect { engine.send(:validate_name!, "") }.to raise_error(Mana::Error)
    end

    it "rejects predicate/bang suffixes (current regex is conservative)" do
      # If we ever relax this, the test forces a deliberate decision.
      expect { engine.send(:validate_name!, "empty?") }.to raise_error(Mana::Error)
      expect { engine.send(:validate_name!, "save!") }.to raise_error(Mana::Error)
    end

    it "rejects non-ASCII letters" do
      # Ruby itself allows unicode identifiers, but our validator restricts
      # to ASCII so attackers can't slip homograph attacks past.
      expect { engine.send(:validate_name!, "résumé") }.to raise_error(Mana::Error)
    end
  end

  describe "#resolve" do
    it "handles names with leading underscore" do
      b = Object.new.instance_eval { _internal = 5; binding }
      e = Mana::Engine.new(b)
      expect(e.send(:resolve, "_internal")).to eq(5)
    end

    it "raises for nonexistent identifiers (not silent nil)" do
      expect { engine.send(:resolve, "self_not_a_var_xyz") }.to raise_error(NameError)
    end
  end
end
