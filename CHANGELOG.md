# Changelog

## [0.5.13] - 2026-04-05

### Changed
- Backends (`Anthropic`, `OpenAI`) now return `{ content: [...], usage: { input_tokens:, output_tokens: } }` instead of a plain content array
- Anthropic streaming (`chat_stream`) captures usage from `message_start` and `message_delta` events
- OpenAI backend normalizes `prompt_tokens`/`completion_tokens` to `input_tokens`/`output_tokens`

### Added
- `Engine#trace_data` — after execution, exposes `{ prompt:, model:, steps:, total_iterations:, timestamp: }` with per-step usage, latency, and tool call details
- LLM call latency measurement via `Process.clock_gettime` in `Engine#llm_call`

## [0.5.12] - 2026-04-04

### Changed
- Reposition ruby-mana as a pure embedded LLM engine; agent features (chat, memory, compaction) moved to ruby-claw
- Rename `Mana::Memory` to `Mana::Context`; `short_term` to `messages`
- Remove `incognito` mechanism from mana (moved to claw layer)
- Remove `remember` tool and `REMEMBER_TOOL` constant (now registered by claw via tool interface)
- Remove long-term memory injection from prompt builder
- Refactor `tool_handler.rb`: case/when dispatch replaced with `BUILTIN_TOOLS` + `send("handle_#{name}")` dispatch map
- Update `eval` tool description to emphasize "define new methods/classes/require" role
- `config.memory_class` renamed to `config.context_class`

### Added
- `Mana.register_tool(definition, &handler)` — external tool registration interface
- `Mana.register_prompt_section(&block)` — external prompt injection interface
- `Mana.tool_handlers` — access registered tool handler map
- `BUILTIN_TOOLS` constant in ToolHandler for dispatch map

### Removed
- `Mana.incognito` / `Context.incognito?` / `Context.incognito` — incognito is now claw's responsibility
- `REMEMBER_TOOL` constant
- `@incognito` instance variable from Engine
- Long-term memory (`long_term`, `remember`, `forget`) from Context

## [0.5.11] - 2026-03-27

### Changed
- Memory storage default path changed from `~/.mana/memory` to `{cwd}/.mana` (project-local)
- Long-term memory injection uses keyword search when collection exceeds 20 memories

### Added
- Session persistence — short-term memory and summaries survive across restarts (`persist_session` config, default: true)
- `Memory#save_session` / auto-load on init for session continuity
- `Memory#search(query, top_k:)` — keyword-based fuzzy matching over long-term memories
- `config.persist_session` (default: `true`) and `config.memory_top_k` (default: `10`) options
- `MemoryStore#read_session` / `#write_session` abstract interface and `FileStore` implementation

## [0.5.10] - 2026-03-27

### Added
- `Mana.chat` — interactive REPL mode with streaming output and colored prompts
- `think` tool — LLM can plan approach before acting on complex tasks
- Streaming support for Anthropic backend (`chat_stream` with SSE parsing)
- Agent behavior guidelines in system prompt (think → read → act → verify)

## [0.5.9] - 2026-03-27

### Added
- `error` tool — LLM can signal task failure, raised as `Mana::LLMError` to the Ruby caller
- Text-only LLM responses (after nudge) now raise `LLMError` instead of returning `nil`

## [0.5.8] - 2026-03-27

### Added
- `local_variables` support — LLM can call `local_variables` via `call_func` to discover variables in scope (binding-routed for correct scoping)

## [0.5.7] - 2026-03-27

### Security
- **call_func receiver validation** — blocks expression injection (e.g. `ENV['HOME'].to_s`) by requiring simple constant names only
- **write_var no longer pollutes receiver** — singleton method fallback only for new variables that don't conflict with existing methods

### Fixed
- Failed LLM calls no longer pollute short-term memory (messages rolled back on exception)
- Logger extracted from engine.rb (726→639 lines)
- Compiler cache includes sibling function signatures (dependency changes invalidate cache)
- Summarize error handling: ConfigError propagates, others log
- OpenAI convert_tools filters $schema key
- docs/index.html version badge, mock example, context_window default

### Added
- `Backends::Base` class with shared HTTP infrastructure
- `Logger` module extracted from Engine
- Tests for read_attr/write_attr error paths, nested error recovery, mixin visibility
- Examples: yard_comments.rb, testing.rb

## [0.5.6] - 2026-03-26

### Added
- **Function comment extraction** — descriptions and @param types from YARD-style comments
- **Keyword argument support** in call_func (kwargs field)
- **Prism AST prompt extraction** — replaces regex, handles multi-line and escaped quotes
- **Instruction sequence fallback** — extracts prompt from bytecode in IRB/eval
- **Cache version locking** — includes gem version + Ruby version in cache hash
- **Method visibility preservation** — mana def respects private/protected
- **Smart log formatting** — code highlighting, auto-summarize long values

### Removed
- **effect_registry** — replaced by plain Ruby functions with comment extraction

### Fixed
- Config naming: unified `security` / `security=` (was `security_policy`)
- Config validation: `validate!` method, timeout=0 blocked
- Config decoupled from Backends module
- Compiler: `:nokey` (**nil) parameter handled
- Compiler: cache works in IRB with auto-invalidation

## [0.5.5] - 2026-03-23

### Added
- **Configurable security policy** — 5 levels from `:sandbox` (0) to `:danger` (4), with fine-grained `allow_receiver`/`block_method` overrides
- **Environment variable config** — `MANA_MODEL`, `MANA_VERBOSE`, `MANA_TIMEOUT`, `MANA_BACKEND`, `MANA_SECURITY`
- **Verbose mode** — `c.verbose = true` logs LLM calls, tool usage, and results to stderr
- **API key validation** — clear `ConfigError` with setup instructions instead of cryptic HTTP 401
- **Long-term memory deduplication** — identical content is no longer stored twice
- **Current prompt overrides memory** — explicit priority rule in system prompt
- **Ruby 4.0 support** — CI tests Ruby 3.3, 3.4, and 4.0

### Fixed
- `write_var` works on Ruby 4.0 without pre-declaring variables (singleton method fallback)
- Blocked Ruby introspection methods (`methods`, `local_variables`, etc.) in `call_func`
- LLM retries once when model skips tool calling and returns text only
- Long-term memory stored in `~/.mana/` instead of platform-specific paths
- Default model changed to `claude-sonnet-4-6`
- Compiler uses isolated binding to prevent `generate()` recursion
- Cache files named by source path with prompt hash validation

### Removed
- Polyglot engine system (JavaScript, Python, language detection)
- `mini_racer` and `pycall` dependencies
- `ObjectRegistry`, `RemoteRef`, engine capability queries

## [0.5.3] - 2026-03-22

### Added
- **Timeout configuration** — `timeout` option in `Mana.configure` (default: 120 seconds)

## [0.5.2] - 2026-03-22

### Added
- **API URL endpoint configuration** — `effective_base_url` auto-resolves per backend
- `ANTHROPIC_API_URL` / `OPENAI_API_URL` environment variables
- API key fallback: `ANTHROPIC_API_KEY` → `OPENAI_API_KEY`

## [0.4.0] - 2026-02-22

- Multi-LLM backend — Anthropic + OpenAI-compatible APIs
- Test mode — `Mana.mock` + `mock_prompt` for stubbing LLM responses

## [0.3.1] - 2026-02-21

- Nested prompts — LLM calling LLM
- Lambda `call_func` support

## [0.3.0] - 2026-02-21

- Automatic memory — context sharing across LLM calls
- Incognito mode
- Persistent long-term memory

## [0.2.0] - 2026-02-20

- Custom effect handlers — user-defined LLM tools
- `mana def` — LLM-compiled methods with file caching
- Auto-discover functions via Prism introspection

## [0.1.0] - 2026-02-19

- Initial release
- `~"..."` syntax for embedding LLM prompts in Ruby
- Effect system: read_var, write_var, read_attr, write_attr, call_func
- Anthropic Claude backend
- Variable binding via `<var>` convention
