# frozen_string_literal: true

module Mana
  # Verbose logging utilities for tracing LLM interactions.
  # Included by Engine — provides vlog, vlog_value, vlog_code, etc.
  # All methods are no-ops unless @config.verbose is true.
  module Logger
    private

    # Log a debug message to stderr
    def vlog(msg)
      return unless @config.verbose

      $stderr.puts "\e[2m[mana] #{msg}\e[0m"
    end

    # Log a value with smart formatting:
    #   - Multi-line strings → highlighted code block
    #   - Long strings (>200 chars) → truncated with char count
    #   - Long arrays/hashes (>5 items) → truncated with item count
    #   - Everything else → inline inspect
    def vlog_value(prefix, value)
      return unless @config.verbose

      case value
      when String
        if value.include?("\n")
          vlog(prefix)
          vlog_code(value)
        elsif value.length > 200
          vlog("#{prefix} #{value[0, 80].inspect}... (#{value.length} chars)")
        else
          vlog("#{prefix} #{value.inspect}")
        end
      when Array
        if value.length > 5
          preview = value.first(3).map(&:inspect).join(", ")
          vlog("#{prefix} [#{preview}, ...] (#{value.length} items)")
        else
          vlog("#{prefix} #{value.inspect}")
        end
      when Hash
        if value.length > 5
          preview = value.first(3).map { |k, v| "#{k.inspect}=>#{v.inspect}" }.join(", ")
          vlog("#{prefix} {#{preview}, ...} (#{value.length} keys)")
        else
          vlog("#{prefix} #{value.inspect}")
        end
      else
        str = value.inspect
        if str.length > 200
          vlog("#{prefix} #{str[0, 80]}... (#{str.length} chars)")
        else
          vlog("#{prefix} #{str}")
        end
      end
    end

    # Log a code block with Ruby syntax highlighting to stderr
    def vlog_code(code)
      return unless @config.verbose

      highlighted = highlight_ruby(code)
      highlighted.each_line do |line|
        $stderr.puts "\e[2m[mana]\e[0m   #{line.rstrip}"
      end
    end

    # Summarize tool input for compact logging.
    # Multi-line string values are replaced with a brief summary.
    def summarize_input(input)
      return input.inspect unless input.is_a?(Hash)

      summarized = input.map do |k, v|
        if v.is_a?(String) && v.include?("\n")
          lines = v.lines.size
          words = v.split.size
          first = v.lines.first&.strip&.slice(0, 30)
          "#{k}: \"#{first}...\" (#{lines} lines, #{words} words)"
        elsif v.is_a?(String) && v.length > 100
          "#{k}: \"#{v[0, 50]}...\" (#{v.length} chars)"
        else
          "#{k}: #{v.inspect}"
        end
      end
      "{#{summarized.join(', ')}}"
    end

    # Minimal Ruby syntax highlighter using ANSI escape codes
    def highlight_ruby(code)
      code
        .gsub(/\b(def|end|do|if|elsif|else|unless|case|when|class|module|return|require|include|raise|begin|rescue|ensure|yield|while|until|for|break|next|nil|true|false|self)\b/) { "\e[35m#{$1}\e[0m" }
        .gsub(/(["'])(?:(?=(\\?))\2.)*?\1/) { "\e[32m#{$&}\e[0m" }
        .gsub(/(#[^\n]*)/) { "\e[2m#{$1}\e[0m" }
        .gsub(/\b(\d+(?:\.\d+)?)\b/) { "\e[33m#{$1}\e[0m" }
        .gsub(/(:[\w]+)/) { "\e[36m#{$1}\e[0m" }
    end
  end
end
