# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mana::Engine do
  before do
    Mana.config.api_key = "test-key"
    Thread.current[:mana_context] = nil
    Thread.current[:mana_memory] = nil
    @tmpdir = Dir.mktmpdir("mana_test")
    Mana.config.memory_store = Mana::FileStore.new(@tmpdir)
  end

  after do
    Thread.current[:mana_context] = nil
    Thread.current[:mana_memory] = nil
    FileUtils.rm_rf(@tmpdir)
    Mana.reset!
  end

  describe ".run" do
    it "handles write_var to create new variables" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "result", "value" => 3.0 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      Mana::Engine.run("compute average and store in <result>", b)
      expect(b.local_variable_get(:result)).to eq(3.0)
    end

    it "handles read_var for existing variables" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "read_var", input: { "name" => "numbers" } }],
        [{ type: "tool_use", id: "t2", name: "write_var", input: { "name" => "total", "value" => 6 } }],
        [{ type: "tool_use", id: "t3", name: "done", input: {} }]
      )

      numbers = [1, 2, 3] # rubocop:disable Lint/UselessAssignment
      b = binding
      Mana::Engine.run("sum <numbers> into <total>", b)
      expect(b.local_variable_get(:total)).to eq(6)
    end

    it "handles read_attr and write_attr on objects" do
      klass = Struct.new(:name, :category, keyword_init: true)
      obj = klass.new(name: "test", category: nil)

      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "read_attr", input: { "obj" => "item", "attr" => "name" } }],
        [{ type: "tool_use", id: "t2", name: "write_attr", input: { "obj" => "item", "attr" => "category", "value" => "urgent" } }],
        [{ type: "tool_use", id: "t3", name: "done", input: {} }]
      )

      item = obj # rubocop:disable Lint/UselessAssignment
      b = binding
      Mana::Engine.run("read <item> name and set category", b)
      expect(obj.category).to eq("urgent")
    end

    it "handles call_func('local_variables') via binding route" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "local_variables" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "c" } }]
      )

      a = 1 # rubocop:disable Lint/UselessAssignment
      b_var = 2 # rubocop:disable Lint/UselessAssignment
      c = 3 # rubocop:disable Lint/UselessAssignment
      bnd = binding
      result = Mana::Engine.run("list all variables with value 3", bnd)
      expect(result).to eq("c")
    end

    it "handles call_func" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "double", "args" => [21] } }],
        [{ type: "tool_use", id: "t2", name: "write_var", input: { "name" => "result", "value" => 42 } }],
        [{ type: "tool_use", id: "t3", name: "done", input: {} }]
      )

      def double(n) = n * 2 # rubocop:disable Lint/UselessMethodDefinition

      b = binding
      Mana::Engine.run("call double(21) and store in <result>", b)
      expect(b.local_variable_get(:result)).to eq(42)
    end

    it "raises when LLM returns no tool calls after nudge" do
      stub_anthropic_text_only("All done!")

      b = binding
      expect { Mana::Engine.run("just say hi", b) }.to raise_error(Mana::LLMError, /LLM did not use tools/)
    end

    it "raises on max iterations exceeded" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            content: [{ type: "tool_use", id: "t1", name: "read_var", input: { "name" => "x" } }],
            usage: { input_tokens: 10, output_tokens: 5 }
          })
        )

      orig = Mana.config.max_iterations
      begin
        Mana.config.max_iterations = 3
        x = 1 # rubocop:disable Lint/UselessAssignment
        b = binding
        expect { Mana::Engine.run("loop forever on <x>", b) }.to raise_error(Mana::MaxIterationsError)
      ensure
        Mana.config.max_iterations = orig
      end
    end

    it "raises on HTTP error" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 500, body: "Internal Server Error")

      b = binding
      expect { Mana::Engine.run("fail", b) }.to raise_error(Mana::LLMError, /HTTP 500/)
    end

    it "raises LLMError when LLM calls error tool" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "error", input: { "message" => "cannot compute: division by zero" } }]
      )

      b = binding
      expect { Mana::Engine.run("divide by zero", b) }.to raise_error(Mana::LLMError, "cannot compute: division by zero")
    end

    it "rolls back memory messages when error tool is called" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "error", input: { "message" => "failed" } }]
      )

      memory = Mana::Context.current
      messages_before = memory.messages.size

      b = binding
      expect { Mana::Engine.run("fail task", b) }.to raise_error(Mana::LLMError)
      expect(memory.messages.size).to eq(messages_before)
    end

    it "returns done result" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "done", input: { "result" => "finished" } }]
      )

      b = binding
      result = Mana::Engine.run("do something", b)
      expect(result).to eq("finished")
    end

    it "rejects invalid variable names in write_var" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "system('rm -rf /')", "value" => 1 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      expect { Mana::Engine.run("try injection", b) }.not_to raise_error
    end

    it "rejects invalid function names in call_func" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "eval('bad')", "args" => [] } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      expect { Mana::Engine.run("try injection", b) }.not_to raise_error
    end

    it "rejects invalid attr names in read_attr" do
      klass = Struct.new(:name, keyword_init: true)
      obj = klass.new(name: "test")

      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "read_attr", input: { "obj" => "item", "attr" => "send('exit')" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      item = obj # rubocop:disable Lint/UselessAssignment
      b = binding
      expect { Mana::Engine.run("try injection", b) }.not_to raise_error
    end

    it "handles read_attr on nonexistent object gracefully" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "read_attr", input: { "obj" => "nonexistent_obj", "attr" => "name" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      # Should not crash — error returned to LLM as tool_result
      expect { Mana::Engine.run("read nonexistent", b) }.not_to raise_error
    end

    it "handles write_attr on nonexistent attribute gracefully" do
      klass = Struct.new(:name, keyword_init: true)
      obj = klass.new(name: "test")

      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_attr", input: { "obj" => "item", "attr" => "nonexistent_field", "value" => "x" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      item = obj # rubocop:disable Lint/UselessAssignment
      b = binding
      expect { Mana::Engine.run("write nonexistent attr", b) }.not_to raise_error
    end

    it "handles multiple tool calls in one response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            content: [
              { type: "tool_use", id: "t1", name: "write_var", input: { "name" => "xx", "value" => 1 } },
              { type: "tool_use", id: "t2", name: "write_var", input: { "name" => "yy", "value" => 2 } }
            ],
            usage: { input_tokens: 10, output_tokens: 5 }
          })
        ).then
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            content: [{ type: "tool_use", id: "t3", name: "done", input: {} }],
            usage: { input_tokens: 10, output_tokens: 5 }
          })
        )

      bnd = binding
      Mana::Engine.run("set xx=1 and yy=2", bnd)
      expect(bnd.local_variable_get(:xx)).to eq(1)
      expect(bnd.local_variable_get(:yy)).to eq(2)
    end

    it "handles unknown tool gracefully" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "nonexistent_tool", input: {} }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      expect { Mana::Engine.run("test", b) }.not_to raise_error
    end

    # remember tool tests moved to claw (remember is now a registered tool from claw)
  end

  describe "#execute" do
    it "runs the tool-calling loop and returns written variable value" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => 42 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      result = engine.execute("set <x> to 42")
      expect(result).to eq(42)
      expect(b.local_variable_get(:x)).to eq(42)
    end
  end

  describe "#trace_data" do
    it "captures usage and timing for each LLM call" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "read_var", input: { "name" => "x" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      x = 42 # rubocop:disable Lint/UselessAssignment
      b = binding
      engine = described_class.new(b)
      engine.execute("read <x>")

      expect(engine.trace_data).to be_a(Hash)
      expect(engine.trace_data[:prompt]).to eq("read <x>")
      expect(engine.trace_data[:model]).to eq(Mana.config.model)
      expect(engine.trace_data[:steps].size).to eq(2)

      step = engine.trace_data[:steps].first
      expect(step[:iteration]).to eq(1)
      expect(step[:latency_ms]).to be_a(Integer)
      expect(step[:usage]).to be_a(Hash)
      expect(step[:usage][:input_tokens]).to eq(10)
      expect(step[:usage][:output_tokens]).to eq(5)
    end

    it "records tool calls in each step" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => 1 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      engine.execute("set x=1")

      step = engine.trace_data[:steps].first
      expect(step[:tool_calls]).to be_a(Array)
      expect(step[:tool_calls].first[:name]).to eq("write_var")
    end
  end

  describe "#build_context" do
    it "reads existing variables referenced in prompt" do
      b = binding.tap { |b|
        b.local_variable_set(:x, 42)
        b.local_variable_set(:y, "hello")
      }
      engine = described_class.new(b)

      ctx = engine.send(:build_context, "use <x> and <y>")
      expect(ctx["x"]).to eq("42")
      expect(ctx["y"]).to eq('"hello"')
    end

    it "skips variables that don't exist yet" do
      b = binding
      engine = described_class.new(b)
      ctx = engine.send(:build_context, "store in <new_var>")
      expect(ctx).to be_empty
    end
  end

  describe "#serialize_value" do
    let(:engine) { described_class.new(binding) }

    it "serializes primitives" do
      expect(engine.send(:serialize_value, 42)).to eq("42")
      expect(engine.send(:serialize_value, 3.14)).to eq("3.14")
      expect(engine.send(:serialize_value, "hello")).to eq('"hello"')
      expect(engine.send(:serialize_value, true)).to eq("true")
      expect(engine.send(:serialize_value, nil)).to eq("nil")
    end

    it "serializes arrays" do
      expect(engine.send(:serialize_value, [1, "two", 3])).to eq('[1, "two", 3]')
    end

    it "serializes hashes" do
      result = engine.send(:serialize_value, { a: 1 })
      expect(result).to include('"a" => 1')
    end

    it "serializes custom objects via instance variables" do
      obj = Object.new
      obj.instance_variable_set(:@name, "Alice")
      obj.instance_variable_set(:@age, 30)
      result = engine.send(:serialize_value, obj)
      expect(result).to include("name")
      expect(result).to include("Alice")
    end

    it "serializes Time objects as readable strings" do
      result = engine.send(:serialize_value, Time.new(2026, 3, 23, 12, 0, 0, "+08:00"))
      expect(result).to include("2026-03-23")
      expect(result).to include("12:00:00")
    end
  end

  describe "call_func with local lambda" do
    it "calls a lambda defined in the binding" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "doubler", "args" => [5] } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      doubler = ->(x) { x * 2 } # rubocop:disable Lint/UselessAssignment
      b = binding
      engine = described_class.new(b)
      result = engine.execute("call doubler(5)")
      expect(result).to eq("ok")
    end
  end

  describe "#extract_tool_uses" do
    let(:engine) { described_class.new(binding) }

    it "extracts tool_use blocks from mixed content" do
      content = [
        { type: "text", text: "thinking..." },
        { type: "tool_use", id: "t1", name: "read_var", input: { "name" => "x" } },
        { type: "text", text: "more thinking" },
        { type: "tool_use", id: "t2", name: "done", input: {} }
      ]
      result = engine.send(:extract_tool_uses, content)
      expect(result.size).to eq(2)
      expect(result.map { |t| t[:name] }).to eq(%w[read_var done])
    end

    it "handles string keys" do
      content = [
        { "type" => "tool_use", "id" => "t1", "name" => "write_var", "input" => { "name" => "x", "value" => 1 } }
      ]
      result = engine.send(:extract_tool_uses, content)
      expect(result.size).to eq(1)
      expect(result.first[:name]).to eq("write_var")
    end

    it "returns [] for non-array input" do
      expect(engine.send(:extract_tool_uses, nil)).to eq([])
      expect(engine.send(:extract_tool_uses, "not an array")).to eq([])
      expect(engine.send(:extract_tool_uses, 42)).to eq([])
    end
  end

  describe "#resolve" do
    it "raises NameError for undefined variable" do
      b = binding
      engine = described_class.new(b)
      expect { engine.send(:resolve, "undefined_var_xyz") }.to raise_error(NameError)
    end
  end

  describe "call_func with dotted methods" do
    it "allows Class.method calls like Time.now" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "Time.now" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      result = engine.execute("get time")
      expect(result).to eq("ok")
    end

    it "blocks expression injection in receiver (e.g. ENV['HOME'].to_s)" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "ENV['HOME'].to_s" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      # Should not crash — error returned to LLM, ENV not leaked
      expect { Mana::Engine.run("get env", b) }.not_to raise_error
    end

    it "blocks arbitrary eval in receiver name" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "Kernel.system('ls')" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      expect { Mana::Engine.run("run command", b) }.not_to raise_error
    end

    it "allows chained calls like Time.now.to_s" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "Time.now.to_s" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      result = engine.execute("get time string")
      expect(result).to eq("ok")
    end

  end

  describe "verbose mode" do
    it "logs to stderr when verbose is true" do
      Mana.config.verbose = true
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      expect { engine.execute("test") }.to output(/LLM call/).to_stderr
      Mana.config.verbose = false
    end

    it "does not log when verbose is false" do
      Mana.config.verbose = false
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      engine = described_class.new(b)
      expect { engine.execute("test") }.not_to output.to_stderr
    end
  end

  describe "#handle_mock" do
    it "matches and returns stubbed values" do
      b = binding
      Mana.mock do
        prompt "test", value: 42
        Mana::Engine.new(b).handle_mock("test prompt")
      end
      expect(b.local_variable_get(:value)).to eq(42)
    end
  end

  describe "call_func with body parameter" do
    it "defines a method via define_method with body" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func",
           input: { "name" => "define_method", "args" => ["factorial"], "body" => "|n| n <= 1 ? 1 : n * factorial(n - 1)" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "defined" } }]
      )

      b = binding
      result = Mana::Engine.run("define factorial function", b)
      expect(result).to eq("defined")
    end
  end

  describe "call_func with keyword arguments" do
    it "passes kwargs to functions" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func",
           input: { "name" => "greet", "kwargs" => { "name" => "Alice", "greeting" => "Hello" } } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      def greet(name:, greeting: "Hi") = "#{greeting}, #{name}!"

      b = binding
      result = Mana::Engine.run("greet Alice", b)
      expect(result).to eq("ok")
    end
  end

  describe ".all_tools" do
    it "includes built-in tools" do
      names = described_class.all_tools.map { |t| t[:name] }
      expect(names).to include("knowledge")
      expect(names).to include("done")
      expect(names).to include("read_var")
    end

    it "includes registered tools" do
      Mana.register_tool({ name: "custom", description: "test", input_schema: { type: "object", properties: {} } }) { "ok" }
      names = described_class.all_tools.map { |t| t[:name] }
      expect(names).to include("custom")
    end
  end

  describe ".knowledge" do
    it "returns content for known topics" do
      %w[memory tools execution overview functions backends configuration].each do |topic|
        result = described_class.knowledge(topic)
        expect(result).to be_a(String)
        expect(result).to include("[source: mana]")
      end
    end

    it "matches partial topic names" do
      result = described_class.knowledge("mem")
      expect(result).to include("memory")
    end

    it "returns ri docs for Ruby classes" do
      ri_output = `ri Array#push 2>/dev/null`.strip rescue ""
      skip "ri docs not available" if ri_output.empty?
      result = described_class.knowledge("Array#push")
      expect(result).to include("[source: ri (Ruby official docs)]")
    end
  end

  describe "knowledge tool execution" do
    it "handles knowledge tool call" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "knowledge", input: { "topic" => "memory" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "answered" } }]
      )

      b = binding
      result = Mana::Engine.run("where is your memory stored?", b)
      expect(result).to eq("answered")
    end
  end

  describe "call_func with unknown constant in chained call" do
    it "returns error for unknown constant" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "call_func", input: { "name" => "NonExistent.foo" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      expect { Mana::Engine.run("call nonexistent", b) }.not_to raise_error
    end
  end

  describe "multiple write_var return value" do
    it "returns Hash when multiple variables are written" do
      stub_anthropic_sequence(
        [
          { type: "tool_use", id: "t1", name: "write_var", input: { "name" => "aa", "value" => 1 } },
          { type: "tool_use", id: "t2", name: "write_var", input: { "name" => "bb", "value" => 2 } }
        ],
        [{ type: "tool_use", id: "t3", name: "done", input: {} }]
      )

      b = binding
      result = Mana::Engine.run("set aa=1 bb=2", b)
      expect(result).to be_a(Hash)
      expect(result[:aa]).to eq(1)
      expect(result[:bb]).to eq(2)
    end

    it "returns single value when one variable is written" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => 42 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      result = Mana::Engine.run("set x=42", b)
      expect(result).to eq(42)
    end
  end

  describe "nil and edge case values in write_var" do
    it "handles writing nil" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => nil } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      Mana::Engine.run("set x to nil", b)
      expect(b.local_variable_get(:x)).to be_nil
    end

    it "handles writing empty array" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => [] } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      Mana::Engine.run("set x to empty", b)
      expect(b.local_variable_get(:x)).to eq([])
    end

    it "handles writing empty string" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "x", "value" => "" } }],
        [{ type: "tool_use", id: "t2", name: "done", input: {} }]
      )

      b = binding
      Mana::Engine.run("set x to empty string", b)
      expect(b.local_variable_get(:x)).to eq("")
    end
  end

  describe "injection validation" do
    it "returns error message for invalid variable name" do
      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t1", name: "write_var", input: { "name" => "system('rm -rf /')", "value" => 1 } }],
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      Mana::Engine.run("try injection", b)
      # Verify the malicious variable was NOT created
      expect(b.local_variables).not_to include(:"system('rm -rf /')")
    end
  end

  describe "unpaired tool_use cleanup" do
    it "strips trailing unpaired tool_use from short-term memory" do
      # Simulate a broken conversation state in memory
      memory = Mana.memory
      memory.messages << { role: "user", content: "test" }
      memory.messages << {
        role: "assistant",
        content: [{ type: "tool_use", id: "t1", name: "read_var", input: { "name" => "x" } }]
      }
      # No tool_result follows — this would cause API 400

      stub_anthropic_sequence(
        [{ type: "tool_use", id: "t2", name: "done", input: { "result" => "ok" } }]
      )

      b = binding
      # Should not raise HTTP 400 — unpaired tool_use should be stripped
      expect { Mana::Engine.run("test", b) }.not_to raise_error
    end
  end
end
