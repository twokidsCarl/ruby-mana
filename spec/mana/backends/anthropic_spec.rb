# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mana::Backends::Anthropic do
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

  describe "#chat" do
    it "sends correct auth headers" do
      stub = stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          headers: {
            "x-api-key" => "test-anthropic-key",
            "anthropic-version" => "2023-06-01",
            "Content-Type" => "application/json"
          }
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({ content: [{ type: "text", text: "hello" }] })
        )

      backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(stub).to have_been_requested
    end

    it "sends request body in Anthropic format" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with { |req|
          body = JSON.parse(req.body)
          body["model"] == "claude-sonnet-4-20250514" &&
            body["max_tokens"] == 4096 &&
            body["system"] == "You are helpful." &&
            body["tools"].is_a?(Array) &&
            body["messages"] == [{ "role" => "user", "content" => "hi" }]
        }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({ content: [] })
        )

      backend.chat(
        system: "You are helpful.",
        messages: [{ role: "user", content: "hi" }],
        tools: tools,
        model: "claude-sonnet-4-20250514"
      )
    end

    it "returns content blocks and usage from response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({
            content: [
              { type: "text", text: "thinking..." },
              { type: "tool_use", id: "t1", name: "done", input: { result: "ok" } }
            ],
            usage: { input_tokens: 100, output_tokens: 50 }
          })
        )

      result = backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(result[:content].size).to eq(2)
      expect(result[:content][0][:type]).to eq("text")
      expect(result[:content][1][:type]).to eq("tool_use")
      expect(result[:content][1][:name]).to eq("done")
      expect(result[:usage][:input_tokens]).to eq(100)
      expect(result[:usage][:output_tokens]).to eq(50)
    end

    it "returns empty content when content is nil" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({})
        )

      result = backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(result[:content]).to eq([])
      expect(result[:usage]).to be_nil
    end

    it "raises LLMError on HTTP error" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 500, body: "Internal Server Error")

      expect {
        backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      }.to raise_error(Mana::LLMError, /HTTP 500/)
    end

    it "sets open_timeout and read_timeout from config.timeout" do
      config.timeout = 10

      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:request).and_return(
        instance_double(Net::HTTPSuccess, is_a?: true, code: "200", body: JSON.generate({ content: [] }))
      )

      backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(http_double).to have_received(:open_timeout=).with(10)
      expect(http_double).to have_received(:read_timeout=).with(10)
    end

    it "applies default timeout of 120 when not overridden" do
      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:request).and_return(
        instance_double(Net::HTTPSuccess, is_a?: true, code: "200", body: JSON.generate({ content: [] }))
      )

      backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(http_double).to have_received(:open_timeout=).with(120)
      expect(http_double).to have_received(:read_timeout=).with(120)
    end

    it "wraps Net::ReadTimeout in LLMError" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_timeout

      expect {
        backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      }.to raise_error(Mana::LLMError, /timed out/)
    end

    it "wraps Net::OpenTimeout in LLMError" do
      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:request).and_raise(Net::OpenTimeout.new("connection timed out"))

      expect {
        backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      }.to raise_error(Mana::LLMError, /timed out/)
    end

    it "uses custom base_url" do
      config.base_url = "https://custom-proxy.example.com"
      stub = stub_request(:post, "https://custom-proxy.example.com/v1/messages")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({ content: [] })
        )

      backend.chat(system: "sys", messages: [], tools: tools, model: "claude-sonnet-4-20250514")
      expect(stub).to have_been_requested
    end
  end
end
