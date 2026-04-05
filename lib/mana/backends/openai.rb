# frozen_string_literal: true

module Mana
  module Backends
    # OpenAI-compatible backend (GPT, Groq, DeepSeek, Ollama, etc.)
    #
    # Translates between Mana's internal format (Anthropic-style) and OpenAI's:
    #   - system prompt: top-level `system` → system message
    #   - tool calls: `tool_use`/`tool_result` blocks → `tool_calls` + `role: "tool"`
    #   - response: `choices` → content blocks
    class OpenAI < Base
      # Translates to OpenAI format, posts, then normalizes back to Anthropic format.
      # Uses max_completion_tokens (not max_tokens) per OpenAI's newer API convention.
      def chat(system:, messages:, tools:, model:, max_tokens: 4096)
        uri = URI("#{@config.effective_base_url}/v1/chat/completions")
        parsed = http_post(uri, {
          model: model,
          max_completion_tokens: max_tokens,
          messages: convert_messages(system, messages),
          tools: convert_tools(tools)
        }, {
          "Authorization" => "Bearer #{@config.api_key}"
        })
        {
          content: normalize_response(parsed),
          usage: normalize_usage(parsed[:usage])
        }
      end

      private

      # Convert Anthropic-style messages to OpenAI format.
      def convert_messages(system, messages)
        result = [{ role: "system", content: system }]

        messages.each do |msg|
          case msg[:role]
          when "user"
            converted = convert_user_message(msg)
            converted.is_a?(Array) ? result.concat(converted) : result << converted
          when "assistant"
            result << convert_assistant_message(msg)
          end
        end

        result
      end

      # Handles three cases for user messages:
      # 1. Plain string — pass through
      # 2. Array of tool_result blocks — convert to OpenAI's "tool" role messages
      #    (OpenAI uses separate messages per tool result, not an array in one message)
      # 3. Array of text blocks — merge into a single string
      def convert_user_message(msg)
        content = msg[:content]

        return { role: "user", content: content } if content.is_a?(String)

        if content.is_a?(Array) && content.all? { |b| (b[:type] || b["type"]) == "tool_result" }
          return content.map do |block|
            {
              role: "tool",
              tool_call_id: block[:tool_use_id] || block["tool_use_id"],
              content: (block[:content] || block["content"]).to_s
            }
          end
        end

        if content.is_a?(Array)
          texts = content.map { |b| b[:text] || b["text"] }.compact
          return { role: "user", content: texts.join("\n") }
        end

        { role: "user", content: content.to_s }
      end

      # Splits Anthropic-style content blocks into OpenAI's separate fields:
      # text goes into :content, tool_use blocks become :tool_calls with JSON-encoded args.
      # OpenAI requires tool call arguments as JSON strings, not parsed objects.
      def convert_assistant_message(msg)
        content = msg[:content]

        return { role: "assistant", content: content } if content.is_a?(String)

        if content.is_a?(Array)
          text_parts = []
          tool_calls = []

          content.each do |block|
            type = block[:type] || block["type"]
            case type
            when "text"
              text_parts << (block[:text] || block["text"])
            when "tool_use"
              tool_calls << {
                id: block[:id] || block["id"],
                type: "function",
                function: {
                  name: block[:name] || block["name"],
                  arguments: JSON.generate(block[:input] || block["input"] || {})
                }
              }
            end
          end

          msg_hash = { role: "assistant" }
          msg_hash[:content] = text_parts.join("\n") unless text_parts.empty?
          msg_hash[:tool_calls] = tool_calls unless tool_calls.empty?
          return msg_hash
        end

        { role: "assistant", content: content.to_s }
      end

      # Anthropic uses input_schema with optional $schema key; OpenAI uses parameters
      # without it. Strip $schema to avoid OpenAI validation errors.
      def convert_tools(tools)
        tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name],
              description: tool[:description] || "",
              parameters: (tool[:input_schema] || {}).reject { |k, _| k.to_s == "$schema" }
            }
          }
        end
      end

      # Convert OpenAI usage fields to our standard format.
      def normalize_usage(usage)
        return nil unless usage
        {
          input_tokens: usage[:prompt_tokens],
          output_tokens: usage[:completion_tokens]
        }
      end

      # Convert OpenAI response to Anthropic-style content blocks.
      # This normalization lets the rest of the engine work with a single format
      # regardless of which backend was used.
      def normalize_response(parsed)
        choice = parsed.dig(:choices, 0, :message)
        return [] unless choice

        blocks = []

        if choice[:content] && !choice[:content].empty?
          blocks << { type: "text", text: choice[:content] }
        end

        # Parse JSON argument strings back into Ruby hashes for tool_use blocks
        if choice[:tool_calls]
          choice[:tool_calls].each do |tc|
            func = tc[:function]
            blocks << {
              type: "tool_use",
              id: tc[:id],
              name: func[:name],
              input: JSON.parse(func[:arguments], symbolize_names: true)
            }
          end
        end

        blocks
      end
    end
  end
end
