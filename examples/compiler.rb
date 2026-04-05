# frozen_string_literal: true

# Example: mana def — LLM compiles methods on first call
require "mana"

# Define a method with natural language — LLM generates the implementation
mana def fibonacci(n)
  ~"return an array of the first n Fibonacci numbers"
end

# First call triggers LLM compilation → cached to .ruby-mana/cache/
puts fibonacci(10).inspect

# View the generated source
puts "\n--- Generated source ---"
puts Mana.source(:fibonacci)

# Second call is pure Ruby — zero API overhead
puts "\nfibonacci(5) = #{fibonacci(5).inspect}"

# Works with classes too
class Converter
  include Mana::Mixin

  mana def celsius_to_fahrenheit(c)
    ~"convert Celsius to Fahrenheit and return the numeric result"
  end

  mana def meters_to_feet(m)
    ~"convert meters to feet and return the numeric result"
  end
end

conv = Converter.new
puts "\n100°C = #{conv.celsius_to_fahrenheit(100)}°F"
puts "1.8m = #{conv.meters_to_feet(1.8)}ft"

puts "\n--- Converter sources ---"
puts Mana.source(:celsius_to_fahrenheit, owner: Converter)
