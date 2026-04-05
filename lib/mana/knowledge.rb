# frozen_string_literal: true

require "shellwords"

module Mana
  # Runtime knowledge base — assembles information about ruby-mana from live code.
  # No static files to maintain; the code IS the source of truth.
  module Knowledge
    class << self
      # Query a topic using a cascading lookup strategy.
      # Priority: mana docs > ruby env > ri (external docs) > runtime introspection > dump all.
      # The fallback chain ensures we always return something useful.
      def query(topic)
        topic_key = topic.to_s.strip.downcase
        sections = all_sections

        # 1. Match mana's own sections (bidirectional substring match for flexibility)
        match = sections.find { |k, _| topic_key.include?(k) || k.include?(topic_key) }
        return "[source: mana]\n#{match.last}" if match

        # 2. Ruby environment info
        return "[source: ruby runtime]\n#{ruby_environment}" if topic_key == "ruby"

        # 3. Try ri (official Ruby documentation)
        ri_result = query_ri(topic.to_s.strip)
        return "[source: ri (Ruby official docs)]\n#{ri_result}" if ri_result

        # 4. Try runtime introspection
        introspect_result = query_introspect(topic.to_s.strip)
        return "[source: ruby introspection]\n#{introspect_result}" if introspect_result

        # 5. Fallback: dump all mana sections so the LLM has full context
        "[source: mana]\n#{sections.values.join("\n\n")}"
      end

      private

      # Query Ruby's ri documentation tool (runs outside bundler to access rdoc).
      # Must escape bundler env because ri needs access to system-wide rdoc files
      # that bundler's isolated gem path would hide.
      def query_ri(topic)
        output = if defined?(Bundler)
          Bundler.with_unbundled_env { `ri --format=markdown #{topic.shellescape} 2>&1` }
        else
          `ri --format=markdown #{topic.shellescape} 2>&1`
        end
        return nil unless $?.success?
        # Truncate long docs to avoid flooding the LLM's context window
        output.length > 3000 ? "#{output[0, 3000]}\n\n... (truncated, #{output.length} chars total)" : output
      rescue
        nil
      end

      # Runtime introspection: resolve as a Ruby constant and inspect it.
      # This gives the LLM live information about classes/modules that may not
      # appear in ri docs (e.g. user-defined or gem classes loaded at runtime).
      def query_introspect(topic)
        const = Object.const_get(topic)
        lines = []
        if const.is_a?(Module)
          lines << "#{const.name} (#{const.is_a?(Class) ? "class" : "module"})"
          # Limit ancestors/methods to avoid overwhelming the LLM context
          lines << "Ancestors: #{const.ancestors.first(8).map(&:name).compact.join(' < ')}" if const.is_a?(Class)
          pub = const.public_instance_methods(false).sort
          lines << "Instance methods (#{pub.size}): #{pub.first(30).join(', ')}#{"..." if pub.size > 30}"
          if const.is_a?(Class)
            class_methods = (const.methods - Object.methods).sort
            lines << "Class methods (#{class_methods.size}): #{class_methods.first(20).join(', ')}#{"..." if class_methods.size > 20}" unless class_methods.empty?
          end
        end
        lines.empty? ? nil : lines.join("\n")
      rescue NameError
        nil
      end

      # Ruby runtime environment info
      def ruby_environment
        <<~TEXT
          Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})
          RUBY_ENGINE: #{RUBY_ENGINE} #{RUBY_ENGINE_VERSION}
          Loaded gems: #{Gem.loaded_specs.keys.sort.join(", ")}
        TEXT
      end

      # All knowledge sections are generated dynamically from live code/config,
      # so they're always up-to-date without maintaining separate doc files.
      def all_sections
        {
          "overview"      => overview,
          "tools"         => tools,
          "memory"        => memory,
          "execution"     => execution,
          "configuration" => configuration,
          "backends"      => backends,
          "functions"     => functions
        }
      end

      def overview
        <<~TEXT
          ruby-mana v#{Mana::VERSION} is a hybrid execution engine for Ruby.
          The LLM handles reasoning and decision-making; Ruby handles actual code execution.
          The operator ~"..." turns a natural-language string into an LLM prompt that can
          read/write live Ruby variables, call Ruby methods, and return values — all within
          the caller's binding.
        TEXT
      end

      def tools
        # Extract tool info directly from Engine's tool definitions
        tool_list = Engine.all_tools.map { |t|
          desc = t[:description]
          props = t[:input_schema][:properties] || {}
          params = props.map { |k, v| "#{k}: #{v[:description] || v['description'] || k}" }.join(", ")
          "- #{t[:name]}(#{params}): #{desc}"
        }

        "Built-in tools:\n#{tool_list.join("\n")}"
      end

      def memory
        <<~TEXT
          ruby-mana manages conversation context via Mana::Context:
          - Short-term context: conversation history within the current process. Each ~"..."
            call appends to it, so consecutive calls share context. Cleared when the process exits.
          - Summaries: compacted conversation summaries from prior rounds.
          Long-term memory and the `remember` tool are provided by agent frameworks (e.g. ruby-claw)
          via Mana's tool registration interface.
        TEXT
      end

      def execution
        <<~TEXT
          How ~"..." works step by step:
          1. ~"..." triggers String#~@ — captures the caller's Binding via binding_of_caller.
          2. Build context — parses <var> references, reads their values, discovers functions via Prism AST.
          3. Build system prompt — assembles rules, memory, variable values, and function signatures.
          4. LLM tool-calling loop — sends prompt to LLM with built-in tools. LLM responds with
             tool calls, Mana executes them against the live Ruby binding, sends results back.
             Loops until done() is called or max_iterations (#{Mana.config.max_iterations}) is reached.
          5. Return value — single write_var returns the value directly; multiple writes return a Hash.
        TEXT
      end

      def configuration
        c = Mana.config
        <<~TEXT
          Current configuration:
          - model: #{c.model}
          - backend: #{c.backend || 'auto-detect'}
          - base_url: #{c.effective_base_url}
          - timeout: #{c.timeout}s
          - max_iterations: #{c.max_iterations}
          - context_window: #{c.context_window}
          - verbose: #{c.verbose}
          All options can be set via Mana.configure { |c| ... } or environment variables
          (MANA_MODEL, MANA_BACKEND, MANA_TIMEOUT, MANA_VERBOSE, ANTHROPIC_API_KEY, OPENAI_API_KEY).
        TEXT
      end

      def backends
        <<~TEXT
          ruby-mana supports multiple LLM backends:
          - Anthropic (Claude) — default, native format
          - OpenAI (GPT) — auto-translated
          - Any OpenAI-compatible API (Gemini, local models, etc.) via custom base_url
          Currently using: #{Mana.config.backend || 'auto-detect'} with model #{Mana.config.model}
          Configure via:
            Mana.configure { |c| c.backend = :openai; c.model = "gpt-4o" }
          Or set environment variables: MANA_BACKEND, MANA_MODEL
        TEXT
      end

      def functions
        <<~TEXT
          Function discovery in ruby-mana:
          - Prism AST parser auto-discovers methods from the caller's source file.
          - YARD-style comments are extracted as descriptions.
          - Methods on the receiver (minus Ruby builtins) are also discovered.
          - No registration or JSON schema needed — just define normal Ruby methods.
          - LLM-compiled methods: `mana def method_name` lets the LLM generate the implementation
            on first call, then caches it on disk (.ruby-mana/cache/).
        TEXT
      end
    end
  end
end
