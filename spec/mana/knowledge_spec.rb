# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mana::Knowledge do
  # ri may not be available in CI environments
  def ri_available?
    system("ri --version > /dev/null 2>&1")
  end

  before do
    Mana.config.api_key = "test-key"
  end

  after { Mana.reset! }

  describe ".query" do
    context "mana sections" do
      %w[overview tools memory execution configuration backends functions].each do |topic|
        it "returns mana content for '#{topic}'" do
          result = described_class.query(topic)
          expect(result).to start_with("[source: mana]")
          expect(result.length).to be > 20
        end
      end

      it "matches partial topic names" do
        result = described_class.query("mem")
        expect(result).to start_with("[source: mana]")
        expect(result).to include("memory")
      end
    end

    context "Ruby environment" do
      it "returns ruby runtime info for 'ruby'" do
        result = described_class.query("ruby")
        expect(result).to start_with("[source: ruby runtime]")
        expect(result).to include("Ruby #{RUBY_VERSION}")
        expect(result).to include(RUBY_PLATFORM)
        expect(result).to include("RUBY_ENGINE")
      end
    end

    context "ri documentation" do
      # ri may be installed but have no docs in CI — check if it actually returns content
      before do
        ri_output = `ri Array#map 2>/dev/null`.strip rescue ""
        skip "ri docs not available" if ri_output.empty?
      end

      it "returns ri docs for 'Array#map'" do
        result = described_class.query("Array#map")
        expect(result).to start_with("[source: ri (Ruby official docs)]")
        expect(result).to include("map")
      end

      it "returns ri docs for a class name" do
        result = described_class.query("Integer")
        expect(result).to start_with("[source: ri (Ruby official docs)]")
        expect(result).to include("Integer")
      end
    end

    context "ri failure logging" do
      # Regression: query_ri used to `rescue nil` silently. Now under verbose
      # mode it logs the actual reason so users can diagnose missing ri.

      it "logs to stderr when ri exits non-zero (verbose mode)" do
        Mana.config.verbose = true
        # Open3.capture3 returns [stdout, stderr, status] — stub a failed run
        failed_status = double("status", success?: false, exitstatus: 1)
        allow(Open3).to receive(:capture3).and_return(["", "ri: nothing known", failed_status])
        expect { described_class.send(:query_ri, "NoSuchClass") }
          .to output(/\[mana knowledge\] ri.*nothing known/).to_stderr
      ensure
        Mana.config.verbose = false
      end

      it "logs to stderr when ri command is not installed (verbose mode)" do
        Mana.config.verbose = true
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "ri")
        expect { described_class.send(:query_ri, "Array") }
          .to output(/ri command not found/).to_stderr
      ensure
        Mana.config.verbose = false
      end

      it "stays silent in non-verbose mode" do
        Mana.config.verbose = false
        failed_status = double("status", success?: false, exitstatus: 1)
        allow(Open3).to receive(:capture3).and_return(["", "ri: nothing known", failed_status])
        expect { described_class.send(:query_ri, "NoSuchClass") }.not_to output.to_stderr
      end
    end

    context "runtime introspection fallback" do
      it "returns introspection when ri has no result" do
        # Use a class that ri might not document but Ruby knows about
        allow(described_class).to receive(:query_ri).and_return(nil)
        result = described_class.query("Array")
        # Could be ri or introspection depending on environment
        expect(result).to be_a(String)
        expect(result).not_to be_empty
      end
    end

    context "fallback" do
      it "returns all mana sections for unknown topics" do
        allow(described_class).to receive(:query_ri).and_return(nil)
        allow(described_class).to receive(:query_introspect).and_return(nil)
        result = described_class.query("completely_unknown_xyz_123")
        expect(result).to start_with("[source: mana]")
        expect(result).to include("ruby-mana")
      end
    end
  end

  describe "source labels" do
    it "labels mana content" do
      expect(described_class.query("tools")).to start_with("[source: mana]")
    end

    it "labels ruby runtime" do
      expect(described_class.query("ruby")).to start_with("[source: ruby runtime]")
    end

    it "labels ri docs" do
      ri_output = `ri Hash#merge 2>/dev/null`.strip rescue ""
      skip "ri docs not available" if ri_output.empty?
      result = described_class.query("Hash#merge")
      expect(result).to start_with("[source: ri (Ruby official docs)]")
    end
  end

  describe "tools section" do
    it "lists all built-in tools dynamically" do
      result = described_class.query("tools")
      %w[read_var write_var read_attr write_attr call_func done error knowledge].each do |tool|
        expect(result).to include(tool)
      end
    end
  end

  describe "configuration section" do
    it "includes current config values" do
      result = described_class.query("configuration")
      expect(result).to include(Mana.config.model)
      expect(result).to include(Mana.config.timeout.to_s)
    end
  end
end
