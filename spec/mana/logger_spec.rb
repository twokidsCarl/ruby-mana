# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mana::Logger do
  # Create a test class that includes Logger, mimicking Engine's setup
  let(:test_class) do
    Class.new do
      include Mana::Logger

      attr_reader :config

      def initialize(verbose:)
        @config = Struct.new(:verbose).new(verbose)
      end

      # Expose private methods for testing
      public :vlog, :vlog_value, :vlog_code, :summarize_input, :highlight_ruby
    end
  end

  describe "#vlog" do
    it "outputs to stderr when verbose is true" do
      logger = test_class.new(verbose: true)
      expect { logger.vlog("test message") }.to output(/\[mana\] test message/).to_stderr
    end

    it "does nothing when verbose is false" do
      logger = test_class.new(verbose: false)
      expect { logger.vlog("test message") }.not_to output.to_stderr
    end
  end

  describe "#vlog_value" do
    context "when verbose is false" do
      it "does nothing" do
        logger = test_class.new(verbose: false)
        expect { logger.vlog_value("prefix:", "value") }.not_to output.to_stderr
      end
    end

    context "with String values" do
      let(:logger) { test_class.new(verbose: true) }

      it "logs multi-line strings as code blocks" do
        expect { logger.vlog_value("code:", "line1\nline2") }.to output(/code:/).to_stderr
      end

      it "truncates long strings (>200 chars)" do
        long_str = "x" * 300
        expect { logger.vlog_value("val:", long_str) }.to output(/300 chars/).to_stderr
      end

      it "logs short strings inline with inspect" do
        expect { logger.vlog_value("val:", "hello") }.to output(/val: "hello"/).to_stderr
      end
    end

    context "with Array values" do
      let(:logger) { test_class.new(verbose: true) }

      it "truncates large arrays (>5 items)" do
        arr = [1, 2, 3, 4, 5, 6, 7]
        expect { logger.vlog_value("arr:", arr) }.to output(/7 items/).to_stderr
      end

      it "shows preview of first 3 items for large arrays" do
        arr = (1..10).to_a
        expect { logger.vlog_value("arr:", arr) }.to output(/1, 2, 3/).to_stderr
      end

      it "logs small arrays inline" do
        expect { logger.vlog_value("arr:", [1, 2, 3]) }.to output(/\[1, 2, 3\]/).to_stderr
      end
    end

    context "with Hash values" do
      let(:logger) { test_class.new(verbose: true) }

      it "truncates large hashes (>5 keys)" do
        hash = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6 }
        expect { logger.vlog_value("hash:", hash) }.to output(/6 keys/).to_stderr
      end

      it "shows preview of first 3 pairs for large hashes" do
        hash = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6 }
        expect { logger.vlog_value("hash:", hash) }.to output(/:a=>1/).to_stderr
      end

      it "logs small hashes inline" do
        expect { logger.vlog_value("hash:", { x: 1 }) }.to output(/x.*1/).to_stderr
      end
    end

    context "with other value types" do
      let(:logger) { test_class.new(verbose: true) }

      it "logs short inspect inline" do
        expect { logger.vlog_value("num:", 42) }.to output(/num: 42/).to_stderr
      end

      it "truncates long inspect strings (>200 chars)" do
        obj = Object.new
        long_inspect = "x" * 300
        allow(obj).to receive(:inspect).and_return(long_inspect)
        expect { logger.vlog_value("obj:", obj) }.to output(/300 chars/).to_stderr
      end
    end
  end

  describe "#vlog_code" do
    it "outputs highlighted code to stderr when verbose" do
      logger = test_class.new(verbose: true)
      expect { logger.vlog_code("def hello\n  puts 'hi'\nend") }.to output(/\[mana\]/).to_stderr
    end

    it "does nothing when verbose is false" do
      logger = test_class.new(verbose: false)
      expect { logger.vlog_code("def hello; end") }.not_to output.to_stderr
    end

    it "outputs each line of code separately" do
      logger = test_class.new(verbose: true)
      output = capture_stderr { logger.vlog_code("line1\nline2\nline3") }
      expect(output.lines.count { |l| l.include?("[mana]") }).to eq(3)
    end
  end

  describe "#summarize_input" do
    let(:logger) { test_class.new(verbose: false) }

    it "inspects non-hash input" do
      expect(logger.summarize_input("hello")).to eq('"hello"')
      expect(logger.summarize_input(42)).to eq("42")
      expect(logger.summarize_input([1, 2])).to eq("[1, 2]")
    end

    it "summarizes multi-line string values in hashes" do
      input = { code: "line1\nline2\nline3" }
      result = logger.summarize_input(input)
      expect(result).to include("3 lines")
      expect(result).to include("words")
    end

    it "truncates long string values (>100 chars) in hashes" do
      input = { data: "x" * 150 }
      result = logger.summarize_input(input)
      expect(result).to include("150 chars")
    end

    it "shows short values inline" do
      input = { name: "hello", value: 42 }
      result = logger.summarize_input(input)
      expect(result).to include('name: "hello"')
      expect(result).to include("value: 42")
    end

    it "wraps output in braces" do
      result = logger.summarize_input({ a: 1 })
      expect(result).to start_with("{")
      expect(result).to end_with("}")
    end
  end

  describe "#highlight_ruby" do
    let(:logger) { test_class.new(verbose: false) }

    it "highlights keywords" do
      result = logger.highlight_ruby("def hello")
      expect(result).to include("\e[35mdef\e[0m")
    end

    it "highlights strings" do
      result = logger.highlight_ruby('"hello world"')
      expect(result).to include("\e[32m")
    end

    it "highlights numbers" do
      result = logger.highlight_ruby("x = 42")
      expect(result).to include("\e[33m42\e[0m")
    end

    it "highlights symbols" do
      result = logger.highlight_ruby(":foo")
      expect(result).to include("\e[36m:foo\e[0m")
    end

    it "highlights comments" do
      result = logger.highlight_ruby("# comment")
      expect(result).to include("\e[2m# comment\e[0m")
    end
  end
end

# Helper to capture stderr output as a string
def capture_stderr
  old_stderr = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old_stderr
end
