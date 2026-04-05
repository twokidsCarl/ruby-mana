# frozen_string_literal: true

# Example: Memory — automatic context sharing across prompts
require "mana"

text1 = "The quick brown fox jumps over the lazy dog"
text2 = "To be or not to be, that is the question"

# Set a preference — LLM remembers this automatically
~"remember: always translate to Japanese, use casual tone"

# First translation — uses the remembered preference
~"translate <text1>, store in <result1>"
puts "1: #{result1}"

# Second translation — still remembers the preference
~"translate <text2>, store in <result2>"
puts "2: #{result2}"

# LLM can reference earlier context
~"which of the two translations was harder? store reason in <analysis>"
puts "Analysis: #{analysis}"
