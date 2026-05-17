# frozen_string_literal: true

require "fileutils"
require "digest"

module Mana
  # Compiler for `mana def` — LLM generates method implementations on first call,
  # caches them as real .rb files, and replaces the method with native Ruby.
  #
  # Usage:
  #   mana def fibonacci(n)
  #     ~"return an array of the first n Fibonacci numbers"
  #   end
  #
  #   fibonacci(10)  # first call → LLM generates code → cached → executed
  #   fibonacci(20)  # subsequent calls → pure Ruby, zero API overhead
  #
  #   Mana.source(:fibonacci)  # view generated source
  module Compiler
    class << self
      # Registry of compiled method sources: { "ClassName#method" => source_code }
      def registry
        @registry ||= {}
      end

      # Cache directory for generated .rb files
      def cache_dir
        @cache_dir || File.join(".ruby-mana", "cache")
      end

      attr_writer :cache_dir

      # Get the generated source for a compiled method
      def source(method_name, owner: nil)
        key = registry_key(method_name, owner)
        registry[key]
      end

      # Compile a method: wrap it so first invocation triggers LLM code generation.
      # On subsequent calls, the generated Ruby code is loaded from cache (zero API cost).
      def compile(owner, method_name)
        original = owner.instance_method(method_name)
        compiler = self
        key = registry_key(method_name, owner)

        # Detect method visibility before we replace it
        visibility = if owner.private_method_defined?(method_name)
                       :private
                     elsif owner.protected_method_defined?(method_name)
                       :protected
                     else
                       :public
                     end

        # Read the prompt from the original method body (the ~"..." string)
        prompt = extract_prompt(original)

        # Build parameter signature for the generated method
        params_desc = describe_params(original)

        # Cache filename based on source file + method name
        source_file = original.source_location&.first
        # Clean up cache files for methods that have been deleted from this
        # source. Memoized so it runs at most once per source file per process.
        scrub_orphaned_caches_once(source_file) if source_file
        # Include gem version, Ruby version, and sibling function signatures so cache
        # auto-invalidates when the gem upgrades, Ruby upgrades, or dependency functions change.
        sibling_methods = begin
          Mana::Introspect.methods_from_file(source_file)
            .reject { |m| m[:name] == method_name.to_s }
            .map { |m| "#{m[:name]}(#{m[:params].join(',')})" }
            .sort.join(";")
        rescue => e
          # Sibling-introspection failure shouldn't break compilation, but
          # silently swallowing it hides real bugs (e.g. Introspect API drift,
          # unreadable source files). Surface under verbose mode.
          $stderr.puts "[mana compiler] sibling introspection failed for #{source_file}: #{e.class}: #{e.message}" if Mana.config.verbose
          ""
        end
        prompt_hash = Digest::SHA256.hexdigest("#{Mana::VERSION}:#{RUBY_VERSION}:#{method_name}:#{params_desc}:#{prompt}:#{sibling_methods}")[0, 16]
        cache_path = cache_file_path(method_name, owner, source_file: source_file)

        # Load from cache if file exists and prompt hash matches
        if File.exist?(cache_path)
          first_line = File.open(cache_path, &:readline) rescue ""
          if first_line.include?(prompt_hash)
            cached = File.read(cache_path)
            generated = cached.lines.reject { |l| l.start_with?("#") }.join.strip
            compiler.registry[key] = generated
            v, $VERBOSE = $VERBOSE, nil
            owner.class_eval(generated, cache_path, 1)
            owner.send(visibility, method_name) unless visibility == :public
            $VERBOSE = v
            return
          end
          # Prompt changed — cache is stale, will regenerate on first call
        end

        # Replace the method with a lazy wrapper that generates code on first call
        old_verbose, $VERBOSE = $VERBOSE, nil
        p_hash = prompt_hash    # capture for closure
        p_text = prompt         # capture for closure
        src_file = source_file  # capture for closure
        owner.define_method(method_name) do |*args, **kwargs, &blk|
          # Generate implementation via LLM
          generated = compiler.generate(method_name, params_desc, prompt)

          # Write to cache file for future runs
          cache_path = compiler.write_cache(method_name, generated, owner, prompt_hash: p_hash, prompt: p_text, source_file: src_file)

          # Store in registry so Mana.source() can retrieve it
          compiler.registry[key] = generated

          # Define the method on the correct owner (not Object) via class_eval
          target_owner = owner
          v, $VERBOSE = $VERBOSE, nil
          target_owner.class_eval(generated, cache_path, 1)
          target_owner.send(visibility, method_name) unless visibility == :public
          $VERBOSE = v

          # Call the now-native method (this wrapper never runs again)
          send(method_name, *args, **kwargs, &blk)
        end
        # Restore original visibility on the wrapper method
        owner.send(visibility, method_name) unless visibility == :public
        $VERBOSE = old_verbose
      end

      # Generate Ruby method source via LLM.
      # Uses an isolated binding so LLM cannot see Compiler internals.
      def generate(method_name, params_desc, prompt)
        engine_prompt = "Write a Ruby method definition `def #{method_name}(#{params_desc})` that: #{prompt}. " \
                        "Return ONLY the complete method definition (def...end), no explanation. " \
                        "Store the code as a string in <code>"

        # Create isolated binding with only `code` variable visible.
        # Use eval to avoid "assigned but unused variable" parse-time warning.
        isolated = Object.new.instance_eval { eval("code = nil; binding") }
        Mana::Engine.new(isolated).execute(engine_prompt)

        code = isolated.local_variable_get(:code)
        # LLM may return literal \n instead of real newlines — unescape them
        code = code.gsub("\\n", "\n").gsub("\\\"", "\"").gsub("\\'", "'") if code.is_a?(String)
        code
      end

      # Path to the cache file for a method.
      # Includes source file path for uniqueness: lib_foo_calculate.rb
      # Build the cache file path for a method.
      # Prefers source-file-based naming for uniqueness; falls back to owner class name.
      def cache_file_path(method_name, owner = nil, source_file: nil)
        parts = []
        if source_file
          # Convert path relative to pwd: lib/foo.rb -> lib_foo
          rel = source_file.sub("#{Dir.pwd}/", "").sub(/\.rb$/, "")
          parts << rel.tr("/", "_")
        elsif owner && owner != Object
          # Use underscored class name when source file is unavailable
          parts << underscore(owner.name)
        end
        parts << method_name.to_s
        File.join(cache_dir, "#{parts.join('_')}.rb")
      end

      # Write generated code to a cache file, return the path
      def write_cache(method_name, source, owner = nil, prompt_hash: nil, prompt: nil, source_file: nil)
        FileUtils.mkdir_p(cache_dir)
        path = cache_file_path(method_name, owner, source_file: source_file)
        header = "# Auto-generated by ruby-mana v#{Mana::VERSION} | ruby #{RUBY_VERSION} | prompt_hash: #{prompt_hash}\n"
        if prompt
          prompt.to_s.each_line { |line| header += "# prompt: #{line.rstrip}\n" }
        end
        header += "# frozen_string_literal: true\n\n"
        File.write(path, "#{header}#{source}\n")
        path
      end

      # Clear all cached files and registry
      def clear!
        FileUtils.rm_rf(cache_dir) if Dir.exist?(cache_dir)
        @registry = {}
        @scrubbed_files = nil
      end

      # Remove cache files for methods that no longer exist in `source_file`.
      #
      # The hash in each cache filename includes the sibling-method signature,
      # so editing a method's prompt or its siblings already triggers
      # regeneration. But *deleting* a `mana def` method leaves its old cache
      # file orphaned on disk indefinitely — it won't be touched by any
      # future compile because no method ever asks for it.
      #
      # This walks cache files matching the source-file prefix, extracts the
      # method name from each, and removes ones whose method is no longer
      # declared in the source. Safe to call repeatedly; idempotent.
      #
      # Returns the array of removed paths (empty if nothing to scrub).
      def scrub_orphaned_caches(source_file)
        return [] unless source_file && File.exist?(source_file)
        return [] unless Dir.exist?(cache_dir)

        # Live method names declared in the source file
        live_methods = begin
          Mana::Introspect.methods_from_file(source_file).map { |m| m[:name].to_s }
        rescue
          # If introspection fails, don't risk deleting anything
          return []
        end
        return [] if live_methods.empty?

        # Build the prefix portion of cache_file_path() for this source file
        rel = source_file.sub("#{Dir.pwd}/", "").sub(/\.rb$/, "")
        prefix = rel.tr("/", "_")
        glob = File.join(cache_dir, "#{prefix}_*.rb")

        removed = []
        Dir.glob(glob).each do |path|
          # The basename is "<prefix>_<method_name>.rb"; recover method_name
          basename = File.basename(path, ".rb")
          next unless basename.start_with?("#{prefix}_")
          method_name = basename.sub(/\A#{Regexp.escape(prefix)}_/, "")
          next if live_methods.include?(method_name)

          File.delete(path)
          removed << path
        end
        removed
      rescue Errno::EACCES, Errno::ENOENT
        # File-system errors during scrub shouldn't kill compilation
        removed || []
      end

      # Memoized scrub: each source file is scrubbed at most once per process
      # so repeated compiles in the same session don't keep stat-ing the FS.
      def scrub_orphaned_caches_once(source_file)
        @scrubbed_files ||= {}
        return if @scrubbed_files[source_file]
        @scrubbed_files[source_file] = true
        scrub_orphaned_caches(source_file)
      end

      private

      def registry_key(method_name, owner = nil)
        if owner && owner != Object
          "#{owner}##{method_name}"
        else
          method_name.to_s
        end
      end

      # Extract the prompt string from the original method.
      # Strategy 1: Parse source file with Prism AST (handles multi-line, heredoc, escapes)
      # Strategy 2: Extract from instruction sequence (fallback for IRB/eval)
      def extract_prompt(unbound_method)
        source_loc = unbound_method.source_location
        return extract_prompt_from_iseq(unbound_method) unless source_loc

        file, line = source_loc
        return extract_prompt_from_iseq(unbound_method) unless file && File.exist?(file)

        # Parse with Prism AST — finds ~@ call on a string node
        source = File.read(file)
        result = Prism.parse(source)

        # Walk AST to find the DefNode at the right line, then find ~@ inside it
        prompt = nil
        queue = [result.value]
        while (node = queue.shift)
          next unless node.respond_to?(:compact_child_nodes)

          if node.is_a?(Prism::DefNode) && node.location.start_line == line
            # Found our method — now find the ~"..." call inside
            inner_queue = node.compact_child_nodes.dup
            while (inner = inner_queue.shift)
              next unless inner.respond_to?(:compact_child_nodes)
              if inner.is_a?(Prism::CallNode) && inner.name == :~@ && inner.receiver.is_a?(Prism::StringNode)
                prompt = inner.receiver.unescaped
                break
              end
              inner_queue.concat(inner.compact_child_nodes)
            end
            break
          end

          queue.concat(node.compact_child_nodes)
        end

        prompt || extract_prompt_from_iseq(unbound_method)
      end

      # Fallback: extract prompt from method instruction sequence (works in IRB/eval).
      # Uses iseq.to_a to find the string literal directly — more reliable than disasm
      # because it preserves real newlines (disasm escapes them as \\n).
      def extract_prompt_from_iseq(unbound_method)
        iseq = RubyVM::InstructionSequence.of(unbound_method)
        return nil unless iseq

        # Walk the flattened instruction array to find putstring/putchilledstring
        flat = iseq.to_a.flatten
        flat.each_with_index do |item, i|
          if (item == :putchilledstring || item == :putstring) && flat[i + 1].is_a?(String)
            return flat[i + 1]
          end
        end
        nil
      rescue => e
        # iseq layout can change across Ruby versions; failure here just means
        # we couldn't extract the literal string — caller falls back gracefully.
        # Log under verbose so version-related regressions are findable.
        $stderr.puts "[mana compiler] iseq string extraction failed: #{e.class}: #{e.message}" if Mana.config.verbose
        nil
      end

      # Build a human-readable parameter signature string from method parameters.
      # Maps each parameter type to its Ruby syntax representation.
      def describe_params(unbound_method)
        unbound_method.parameters.map do |(type, name)|
          case type
          when :req then name.to_s            # required positional
          when :opt then "#{name}=nil"         # optional positional
          when :rest then "*#{name}"           # splat
          when :keyreq then "#{name}:"         # required keyword
          when :key then "#{name}: nil"        # optional keyword
          when :keyrest then "**#{name}"       # double splat
          when :block then "&#{name}"          # block parameter
          when :nokey then nil                 # **nil — skip (no keywords accepted)
          else name&.to_s
          end
        end.compact.join(", ")
      end

      def underscore(str)
        return "anonymous" if str.nil? || str.empty?

        str.gsub("::", "_")
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end
    end
  end
end
