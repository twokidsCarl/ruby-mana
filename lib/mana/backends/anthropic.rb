# frozen_string_literal: true

module Mana
  module Backends
    # Native Anthropic Claude backend.
    #
    # Sends requests directly to the Anthropic Messages API (/v1/messages).
    # No format conversion needed — Mana's internal format matches Anthropic's.
    class Anthropic < Base
      # Non-streaming request. Returns content blocks directly since our internal
      # format already matches Anthropic's — no normalization needed (unlike OpenAI).
      def chat(system:, messages:, tools:, model:, max_tokens: 4096)
        uri = URI("#{@config.effective_base_url}/v1/messages")
        parsed = http_post(uri, { model:, max_tokens:, system:, tools:, messages: }, {
          "x-api-key" => @config.api_key,
          "anthropic-version" => "2023-06-01"
        })
        {
          content: parsed[:content] || [],
          usage: parsed[:usage]
        }
      end

      # Streaming variant — yields {type: :text_delta, text: "..."} events.
      # Returns the complete content blocks array (same format as chat).
      def chat_stream(system:, messages:, tools:, model:, max_tokens: 4096, &on_event)
        uri = URI("#{@config.effective_base_url}/v1/messages")
        content_blocks = []
        current_block = nil
        usage = {}

        # Anthropic streams SSE events that incrementally build content blocks.
        # We reassemble them into the same format that chat() returns.
        http_post_stream(uri, {
          model:, max_tokens:, system:, tools:, messages:, stream: true
        }, {
          "x-api-key" => @config.api_key,
          "anthropic-version" => "2023-06-01"
        }) do |event|
          case event[:type]
          when "message_start"
            usage[:input_tokens] = event.dig(:message, :usage, :input_tokens)
          when "message_delta"
            usage[:output_tokens] = event.dig(:usage, :output_tokens)
          when "content_block_start"
            current_block = event[:content_block].dup
            # Tool input arrives as JSON fragments — accumulate as a string, parse on stop
            current_block[:input] = +"" if current_block[:type] == "tool_use"
          when "content_block_delta"
            delta = event[:delta]
            if delta[:type] == "text_delta"
              current_block[:text] = (current_block[:text] || +"") << delta[:text]
              on_event&.call(type: :text_delta, text: delta[:text])
            elsif delta[:type] == "input_json_delta"
              current_block[:input] << delta[:partial_json]
            end
          when "content_block_stop"
            # Parse the accumulated JSON string into a Ruby hash for tool_use blocks
            if current_block && current_block[:type] == "tool_use"
              current_block[:input] = begin
                JSON.parse(current_block[:input], symbolize_names: true)
              rescue JSON::ParserError
                {}
              end
            end
            content_blocks << current_block if current_block
            current_block = nil
          end
        end

        {
          content: content_blocks,
          usage: usage.empty? ? nil : usage
        }
      end
    end
  end
end
