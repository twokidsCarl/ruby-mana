# frozen_string_literal: true

module Mana
  # Dispatches LLM tool calls to their respective handlers.
  # Mixed into Engine as a private method.
  #
  # Built-in tools are dispatched via instance methods (handle_<name>),
  # which can access @binding, @written_vars, etc.
  # External tools (registered via Mana.register_tool) are dispatched via Procs
  # that only receive input — they cannot access the engine's binding.
  #
  # === Return value contract
  #
  # Tool handlers return a String that gets sent back to the LLM as the
  # tool_result content. The convention:
  #
  #   "ok: ..."     — successful mutation (write_var, write_attr)
  #   "error: ..."  — recoverable failure; the LLM sees this and can adjust
  #   <other str>   — query result (the value, JSON, or rendered text)
  #
  # For unrecoverable failures (the "error" tool, or anything the engine
  # should stop on), raise Mana::LLMError instead of returning a string —
  # handle_effect re-raises it so the outer loop terminates cleanly.
  module ToolHandler
    BUILTIN_TOOLS = %w[read_var write_var read_attr write_attr call_func eval knowledge done error].freeze

    # Standardized prefixes — keep in sync with the contract above.
    TOOL_ERROR_PREFIX = "error: "
    TOOL_OK_PREFIX    = "ok: "

    private

    # Format a recoverable tool error consistently. Use this anywhere a
    # handler wants to report a failure back to the LLM.
    def tool_error(message)
      "#{TOOL_ERROR_PREFIX}#{message}"
    end

    # Dispatch a single tool call from the LLM.
    def handle_effect(tool_use)
      name = tool_use[:name]
      input = tool_use[:input] || {}
      # Normalize keys to strings for consistent access
      input = input.transform_keys(&:to_s) if input.is_a?(Hash)

      if BUILTIN_TOOLS.include?(name)
        send("handle_#{name}", input)
      elsif (handler = Mana.tool_handlers[name])
        handler.call(input)
      else
        tool_error("unknown tool #{name}")
      end
    rescue LLMError
      # LLMError must propagate to the caller (e.g. from the error tool)
      raise
    rescue ScriptError, StandardError => e
      # ScriptError covers SyntaxError, LoadError, NotImplementedError
      # StandardError covers everything else (NameError, TypeError, etc.)
      tool_error("#{e.class}: #{e.message}")
    end

    # --- Built-in tool handlers ---

    def handle_read_var(input)
      val = serialize_value(resolve(input["name"]))
      vlog_value("   ↩ #{input['name']} =", val)
      val
    end

    def handle_write_var(input)
      var_name = input["name"]
      value = input["value"]
      write_local(var_name, value)
      @written_vars[var_name] = value
      vlog_value("   ✅ #{var_name} =", value)
      "ok: #{var_name} = #{value.inspect}"
    end

    def handle_read_attr(input)
      obj = resolve(input["obj"])
      validate_name!(input["attr"])
      serialize_value(obj.public_send(input["attr"]))
    end

    def handle_write_attr(input)
      obj = resolve(input["obj"])
      validate_name!(input["attr"])
      obj.public_send("#{input['attr']}=", input["value"])
      "ok: #{input['obj']}.#{input['attr']} = #{input['value'].inspect}"
    end

    def handle_knowledge(input)
      self.class.knowledge(input["topic"])
    end

    def handle_done(input)
      done_val = input["result"]
      vlog_value("🏁 Done:", done_val)
      vlog("═" * 60)
      input["result"].to_s
    end

    def handle_error(input)
      msg = input["message"] || "LLM reported an error"
      vlog("❌ Error: #{msg}")
      vlog("═" * 60)
      raise Mana::LLMError, msg
    end

    def handle_eval(input)
      result = @binding.eval(input["code"])
      vlog_value("   ↩ eval →", result)
      serialize_value(result)
    end

    # --- call_func and helpers ---

    # Handle call_func tool: chained calls, block bodies, simple calls
    def handle_call_func(input)
      func = input["name"]
      args = input["args"] || []
      kwargs = (input["kwargs"] || {}).transform_keys(&:to_sym)
      body_code = input["body"]
      block = @binding.eval("proc { #{body_code} }") if body_code

      # Handle chained calls (e.g. Time.now, Array.new, File.read)
      if func.include?(".")
        return handle_chained_call(func, args, block)
      end

      # Handle body parameter for simple (non-chained) function calls
      if body_code
        validate_name!(func)
        receiver = @binding.receiver
        result = receiver.send(func.to_sym, *args, &block)
        vlog("   ↩ #{func}(#{args.inspect}) with body → #{result.inspect}")
        return serialize_value(result)
      end

      # Simple (non-chained) function call
      validate_name!(func)

      # Binding-sensitive method: local_variables returns scope-dependent results
      if func == "local_variables"
        return handle_local_variables
      end

      # Try local variable (lambdas/procs) first, then receiver methods
      callable = if @binding.local_variables.include?(func.to_sym)
                   @binding.local_variable_get(func.to_sym)
                 elsif @binding.receiver.respond_to?(func.to_sym, true)
                   @binding.receiver.method(func.to_sym)
                 else
                   raise NameError, "undefined function '#{func}'"
                 end
      result = kwargs.empty? ? callable.call(*args) : callable.call(*args, **kwargs)
      call_desc = args.map(&:inspect).concat(kwargs.map { |k, v| "#{k}: #{v.inspect}" }).join(", ")
      vlog_value("   ↩ #{func}(#{call_desc}) →", result)
      serialize_value(result)
    end

    # Handle chained method calls like Time.now, Array.new(10) { rand }
    def handle_chained_call(func, args, block)
      first_dot = func.index(".")
      receiver_name = func[0...first_dot]
      rest = func[(first_dot + 1)..]
      methods_chain = rest.split(".")
      first_method = methods_chain.first

      # Validate receiver is a simple constant name (e.g. "Time", "File", "Math")
      unless receiver_name.match?(/\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/)
        raise NameError, "'#{receiver_name}' is not a valid constant name"
      end

      begin
        receiver = @binding.eval(receiver_name)
      rescue => e
        raise NameError, "cannot resolve '#{receiver_name}': #{e.message}"
      end
      result = receiver.public_send(first_method.to_sym, *args, &block)

      # Chain remaining methods without args (e.g. .to_s, .strftime)
      methods_chain[1..].each do |m|
        result = result.public_send(m.to_sym)
      end

      vlog_value("   ↩ #{func}(#{args.map(&:inspect).join(', ')}) →", result)
      serialize_value(result)
    end

    # Handle local_variables call with Mana-created singleton method tracking
    def handle_local_variables
      result = @binding.local_variables.map(&:to_s)
      receiver = @binding.receiver
      if receiver.instance_variable_defined?(:@__mana_vars__)
        result = (result + receiver.instance_variable_get(:@__mana_vars__).map(&:to_s)).uniq
      end
      vlog("   ↩ local_variables() → #{result.size} variables")
      serialize_value(result)
    end
  end
end
