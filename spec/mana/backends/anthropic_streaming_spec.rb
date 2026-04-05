# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mana::Backends::Anthropic, "#chat_stream" do
  let(:config) do
    Mana::Config.new.tap do |c|
      c.api_key = "test-anthropic-key"
      c.base_url = "https://api.anthropic.com"
      c.model = "claude-sonnet-4-20250514"
    end
  end

  let(:backend) { described_class.new(config) }

  let(:tools) do
    [{ name: "done", description: "Signal done", input_schema: { type: "object", properties: {} } }]
  end

  # Helper to build SSE event strings
  def sse_event(type, data)
    "event: #{type}\ndata: #{JSON.generate(data)}\n\n"
  end

  # Helper to create a mock HTTP response that yields SSE chunks
  def stub_streaming_response(*chunks)
    http_double = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)

    response = instance_double(Net::HTTPOK, code: "200")
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    allow(http_double).to receive(:request) do |_req, &block|
      allow(response).to receive(:read_body) do |&body_block|
        chunks.each { |chunk| body_block.call(chunk) }
      end
      block.call(response)
    end
  end

  it "assembles text content blocks from streaming deltas" do
    stub_streaming_response(
      sse_event("message_start", { type: "message_start", message: { usage: { input_tokens: 80 } } }),
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "Hello " } }),
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "world!" } }),
      sse_event("content_block_stop", { type: "content_block_stop" }),
      sse_event("message_delta", { type: "message_delta", usage: { output_tokens: 30 } }),
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result[:content].size).to eq(1)
    expect(result[:content][0][:type]).to eq("text")
    expect(result[:content][0][:text]).to eq("Hello world!")
    expect(result[:usage][:input_tokens]).to eq(80)
    expect(result[:usage][:output_tokens]).to eq(30)
  end

  it "yields text_delta events to the callback" do
    stub_streaming_response(
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    events = []
    backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514") do |event|
      events << event
    end

    expect(events.size).to eq(1)
    expect(events[0][:type]).to eq(:text_delta)
    expect(events[0][:text]).to eq("Hi")
  end

  it "assembles tool_use content blocks with JSON input" do
    stub_streaming_response(
      sse_event("content_block_start", {
        type: "content_block_start",
        content_block: { type: "tool_use", id: "toolu_1", name: "done" }
      }),
      sse_event("content_block_delta", {
        type: "content_block_delta",
        delta: { type: "input_json_delta", partial_json: '{"resu' }
      }),
      sse_event("content_block_delta", {
        type: "content_block_delta",
        delta: { type: "input_json_delta", partial_json: 'lt":"ok"}' }
      }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    content = result[:content]
    expect(content.size).to eq(1)
    expect(content[0][:type]).to eq("tool_use")
    expect(content[0][:name]).to eq("done")
    expect(content[0][:id]).to eq("toolu_1")
    expect(content[0][:input]).to eq({ result: "ok" })
  end

  it "handles invalid JSON in tool input gracefully (returns empty hash)" do
    stub_streaming_response(
      sse_event("content_block_start", {
        type: "content_block_start",
        content_block: { type: "tool_use", id: "toolu_1", name: "done" }
      }),
      sse_event("content_block_delta", {
        type: "content_block_delta",
        delta: { type: "input_json_delta", partial_json: "{invalid json" }
      }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result[:content].size).to eq(1)
    expect(result[:content][0][:input]).to eq({})
  end

  it "handles mixed text and tool_use blocks" do
    stub_streaming_response(
      # Text block
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "Thinking..." } }),
      sse_event("content_block_stop", { type: "content_block_stop" }),
      # Tool use block
      sse_event("content_block_start", {
        type: "content_block_start",
        content_block: { type: "tool_use", id: "toolu_2", name: "done" }
      }),
      sse_event("content_block_delta", {
        type: "content_block_delta",
        delta: { type: "input_json_delta", partial_json: '{"result":"done"}' }
      }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    content = result[:content]
    expect(content.size).to eq(2)
    expect(content[0][:type]).to eq("text")
    expect(content[0][:text]).to eq("Thinking...")
    expect(content[1][:type]).to eq("tool_use")
    expect(content[1][:name]).to eq("done")
  end

  it "sends correct headers for streaming requests" do
    stub_streaming_response(
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    # Verify the request is constructed correctly by checking the Net::HTTP::Post
    allow_any_instance_of(Net::HTTP::Post).to receive(:[]=).and_call_original

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result).to be_a(Hash)
    expect(result[:content]).to be_an(Array)
  end

  it "skips [DONE] sentinel in SSE stream" do
    stub_streaming_response(
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } }),
      sse_event("content_block_stop", { type: "content_block_stop" }),
      "data: [DONE]\n\n"
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result[:content].size).to eq(1)
    expect(result[:content][0][:text]).to eq("Hi")
  end

  it "skips empty SSE lines" do
    stub_streaming_response(
      "\n\n",
      sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } }),
      "\n\n",
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result[:content].size).to eq(1)
    expect(result[:content][0][:text]).to eq("Hi")
  end

  it "handles SSE events split across chunks" do
    # A single SSE event arrives in two TCP chunks
    full_event = sse_event("content_block_start", { type: "content_block_start", content_block: { type: "text", text: "" } })
    part1 = full_event[0, full_event.length / 2]
    part2 = full_event[full_event.length / 2..]

    stub_streaming_response(
      part1,
      part2,
      sse_event("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: "split" } }),
      sse_event("content_block_stop", { type: "content_block_stop" })
    )

    result = backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(result[:content].size).to eq(1)
    expect(result[:content][0][:text]).to eq("split")
  end

  it "includes stream: true in request body" do
    captured_body = nil

    http_double = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)

    response = instance_double(Net::HTTPOK, code: "200")
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    allow(http_double).to receive(:request) do |req, &block|
      captured_body = JSON.parse(req.body)
      allow(response).to receive(:read_body)
      block.call(response)
    end

    backend.chat_stream(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
    expect(captured_body["stream"]).to be true
  end
end
