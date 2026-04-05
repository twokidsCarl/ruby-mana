# ruby-mana 🔮

[![Gem Version](https://badge.fury.io/rb/ruby-mana.svg)](https://rubygems.org/gems/ruby-mana) · [Website](https://twokidscarl.github.io/ruby-mana/) · [RubyGems](https://rubygems.org/gems/ruby-mana) · [GitHub](https://github.com/twokidsCarl/ruby-mana)

**Looking for interactive chat, persistent memory, and agent features?** See [ruby-claw](https://github.com/twokidsCarl/ruby-claw).

Embed LLM as native Ruby. Write natural language, it just runs. Not an API wrapper — a language construct that weaves LLM into your code.

```ruby
require "mana"

numbers = [1, "2", "three", "cuatro", "五"]
~"compute the semantic average of <numbers> and store in <result>"
puts result  # => 3.0
```

## Install

```bash
gem install ruby-mana
```

Or in your Gemfile:

```ruby
gem "ruby-mana"
```

Requires Ruby 3.3+ (including 4.0) and an API key (Anthropic, OpenAI, or compatible):

```bash
export ANTHROPIC_API_KEY=your_key_here
export ANTHROPIC_API_URL=https://api.anthropic.com  # optional, this is the default
# or
export OPENAI_API_KEY=your_key_here
export OPENAI_API_URL=https://api.openai.com        # optional, this is the default
```

Supports Ruby 3.3, 3.4, and 4.0 — no API differences between versions.

## Usage

Prefix any string with `~` to make it an LLM prompt:

```ruby
require "mana"

numbers = [1, 2, 3, 4, 5]
~"compute the average of <numbers> and store in <result>"
puts result
```

### Variables

Use `<var>` to reference variables. Mana figures out read vs write:

- Variable exists in scope → Mana reads it and passes to LLM
- Variable doesn't exist → LLM creates it via `write_var`

```ruby
name = "Alice"
scores = [85, 92, 78, 95, 88]

~"analyze <scores> for <name>, store the mean in <average>, the highest in <best>, and a short comment in <comment>"

puts average  # => 87.6
puts best     # => 95
puts comment  # => "Excellent and consistent performance"
```

### Object manipulation

LLM can read and write object attributes:

```ruby
class Email
  attr_accessor :subject, :body, :category, :priority
end

email = Email.new
email.subject = "URGENT: Server down"
email.body = "Database connection pool exhausted..."

~"read <email> subject and body, then set its category and priority"

puts email.category  # => "urgent"
puts email.priority   # => "high"
```

### Calling Ruby functions

LLM discovers and calls your Ruby functions automatically. Add YARD comments for better understanding:

```ruby
# Look up stock price by symbol
# @param symbol [String] ticker symbol
def fetch_price(symbol)
  { "AAPL" => 189.5, "GOOG" => 141.2, "TSLA" => 248.9 }[symbol] || 0
end

def send_alert(msg)
  puts "[ALERT] #{msg}"
end

portfolio = ["AAPL", "GOOG", "TSLA", "MSFT"]

~"iterate <portfolio>, call fetch_price for each, send_alert if price > 200, store the sum in <total>"
puts total  # => 579.6
```

The LLM sees your functions with descriptions and types:
```
Available Ruby functions:
  fetch_price(symbol) — Look up stock price by symbol
  send_alert(msg)
```

Both positional and keyword arguments are supported. Functions are discovered from the source file (via Prism AST) and from methods defined on `self`.

### LLM-compiled methods

`mana def` lets LLM generate a method implementation on first call. The generated code is cached as a real `.rb` file — subsequent calls are pure Ruby with zero API overhead.

```ruby
mana def fibonacci(n)
  ~"return an array of the first n Fibonacci numbers"
end

fibonacci(10)  # first call → LLM generates code → cached
fibonacci(20)  # second call → loads from cache, no LLM, no waiting

# View the generated source
puts Mana.source(:fibonacci)

# Works in classes too
class Converter
  include Mana::Mixin

  mana def celsius_to_fahrenheit(c)
    ~"convert Celsius to Fahrenheit"
  end
end

puts Mana.source(:celsius_to_fahrenheit, owner: Converter)
```

Generated files live in `.ruby-mana/cache/` (add to `.gitignore`, or commit them to skip LLM on CI).

## Advanced

### Mixed control flow

Ruby handles the structure, LLM handles the decisions:

```ruby
player_hp = 100
enemy_hp = 80
inventory = ["sword", "potion", "shield"]

while player_hp > 0 && enemy_hp > 0
  ~"player HP=<player_hp>, enemy HP=<enemy_hp>, inventory=<inventory>, choose an action and store in <action>"

  case action
  when "attack" then enemy_hp -= rand(15..25)
  when "defend" then nil
  when "use_item"
    ~"pick a healing item from <inventory> and store its name in <item_name>"
    inventory.delete(item_name)
    player_hp += 25
  end

  player_hp -= action == "defend" ? rand(5..10) : rand(10..20)
end
```

### Nested prompts

Functions called by LLM can themselves contain `~"..."` prompts:

```ruby
lint = ->(code) { ~"check #{code} for style issues, store in <issues>" }
# Equivalent to:
# def lint(code)
#   ~"check #{code} for style issues, store in <issues>"
#   issues
# end

~"review <codebase>, call lint for each file, store report in <report>"
```

Each nested call gets its own conversation context. The outer LLM only sees the function's return value, keeping its context clean.

## Configuration

All options can be set via environment variables (`.env` file) or `Mana.configure`:

```bash
# .env — just source it: `source .env`
export ANTHROPIC_API_KEY=sk-your-key-here
export ANTHROPIC_API_URL=https://api.anthropic.com   # optional, custom endpoint
export MANA_MODEL=claude-sonnet-4-6                  # default model
export MANA_VERBOSE=true                             # show LLM interactions
export MANA_TIMEOUT=120                              # HTTP timeout in seconds
export MANA_BACKEND=anthropic                        # force backend (anthropic/openai)
```

| Environment Variable | Config | Default | Description |
|---------------------|--------|---------|-------------|
| `ANTHROPIC_API_KEY` | `c.api_key` | — | API key (required) |
| `OPENAI_API_KEY` | `c.api_key` | — | Fallback API key |
| `ANTHROPIC_API_URL` | `c.base_url` | auto-detect | Custom API endpoint |
| `OPENAI_API_URL` | `c.base_url` | auto-detect | Fallback endpoint |
| `MANA_MODEL` | `c.model` | `claude-sonnet-4-6` | LLM model name |
| `MANA_VERBOSE` | `c.verbose` | `false` | Log LLM calls to stderr |
| `MANA_TIMEOUT` | `c.timeout` | `120` | HTTP timeout (seconds) |
| `MANA_BACKEND` | `c.backend` | auto-detect | Force `anthropic` or `openai` |

Programmatic config (overrides env vars):

```ruby
Mana.configure do |c|
  c.model = "claude-sonnet-4-6"
  c.temperature = 0
  c.api_key = "sk-..."
  c.verbose = true
  c.timeout = 120
  c.max_iterations = 20           # max tool-call rounds per prompt
  c.namespace = "my-project"      # nil = auto-detect from git/pwd
  c.context_window = 128_000      # default: 128_000
  c.memory_store = Mana::FileStore.new  # default file-based persistence
  c.memory_path = ".ruby-mana"    # directory for memory files
  c.context_class = nil           # custom context class (e.g. from agent frameworks)
  c.knowledge_provider = nil      # custom knowledge provider
end
```

## Testing

Use `Mana.mock` to test code that uses `~"..."` without calling any API:

```ruby
require "mana"

RSpec.describe MyApp do
  include Mana::TestHelpers

  it "writes variables into caller scope" do
    # Each key becomes a local variable via write_var
    mock_prompt "analyze", bugs: ["XSS"], score: 8.5

    ~"analyze <code> and store bugs in <bugs> and score in <score>"
    expect(bugs).to eq(["XSS"])
    expect(score).to eq(8.5)
  end

  it "returns a value via _return" do
    mock_prompt "translate", _return: "你好"

    result = ~"translate hello to Chinese"
    expect(result).to eq("你好")
  end

  it "uses block for dynamic responses" do
    mock_prompt(/translate/) do |prompt|
      { output: prompt.include?("Chinese") ? "你好" : "hello" }
    end

    ~"translate hi to Chinese, store in <output>"
    expect(output).to eq("你好")
  end
end
```

**How mock works:**
- `mock_prompt(pattern, key: value, ...)` — each key/value pair is written as a local variable (simulates `write_var`)
- `_return:` — special key, becomes the return value of `~"..."`
- Block form — receives the prompt text, returns a hash of variables to write
- Pattern matching: `String` uses `include?`, `Regexp` uses `match?`

Block mode for inline tests:

```ruby
Mana.mock do
  prompt "summarize", summary: "A brief overview"

  text = "Long article..."
  ~"summarize <text> and store in <summary>"
  puts summary  # => "A brief overview"
end
```

Unmatched prompts raise `Mana::MockError` with a helpful message suggesting the stub to add.

## How it works

```
  Your Ruby code                        LLM (Claude/GPT/...)
  ─────────────                         ────────────────────
  numbers = [1, 2, 3]
  ~"average of <numbers>,          ──→  system prompt:
    store in <result>"                    - rules + tools
                                          - variables: numbers = [1,2,3]
                                          - available functions

                                    ←──  tool_call: read_var("numbers")
  return [1, 2, 3]                 ──→

                                    ←──  tool_call: write_var("result", 2.0)
  binding.local_variable_set       ──→   ok

                                    ←──  tool_call: done(result: 2.0)
  result == 2.0 ✓
```

**Step by step:**

1. **`~"..."` triggers `String#~@`** — captures the caller's `Binding` via `binding_of_caller`, giving Mana access to local variables, methods, and objects in scope.

2. **Build context** — parses `<var>` references from the prompt, reads their current values, discovers available functions via Prism AST (with YARD descriptions if present).

3. **Build system prompt** — assembles rules, variable values, and function signatures into a single system prompt.

4. **LLM tool-calling loop** — sends prompt to the LLM with built-in tools (`read_var`, `write_var`, `read_attr`, `write_attr`, `call_func`, `done`, `error`, `eval`, `knowledge`). The LLM responds with tool calls, Mana executes them against the live Ruby binding, and sends results back. This loops until `done` is called or no more tool calls are returned.

5. **Return value** — single `write_var` returns the value directly; multiple writes return a Hash. On Ruby 4.0+, a singleton method fallback ensures variables are accessible in the caller's scope.


## License

MIT
