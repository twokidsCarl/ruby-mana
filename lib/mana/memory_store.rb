# frozen_string_literal: true

require "json"
require "fileutils"

module Mana
  # Abstract base class for long-term memory persistence.
  # Subclass and implement read/write/clear to use a custom store (e.g. Redis, DB).
  class MemoryStore
    # Read all memories for a namespace. Subclasses must implement.
    def read(namespace)
      raise NotImplementedError
    end

    # Write all memories for a namespace. Subclasses must implement.
    def write(namespace, memories)
      raise NotImplementedError
    end

    # Delete all memories for a namespace. Subclasses must implement.
    def clear(namespace)
      raise NotImplementedError
    end
  end


  # Default file-based memory store. Persists memories as JSON files.
  # Storage path resolution: explicit base_path > config.memory_path > {cwd}/.ruby-mana
  class FileStore < MemoryStore
    # Optional base_path overrides default storage location
    def initialize(base_path = nil)
      @base_path = base_path
    end

    # Read all memories for a namespace from disk. Returns [] on missing file or parse error.
    def read(namespace)
      path = file_path(namespace)
      return [] unless File.exist?(path)

      data = JSON.parse(File.read(path), symbolize_names: true)
      data.is_a?(Array) ? data : []
    # Corrupted JSON file — return empty array rather than crashing
    rescue JSON::ParserError
      []
    end

    # Write all memories for a namespace to disk (overwrites existing file)
    def write(namespace, memories)
      path = file_path(namespace)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(memories))
    end

    # Delete the memory file for a namespace
    def clear(namespace)
      path = file_path(namespace)
      File.delete(path) if File.exist?(path)
    end

    private

    # Build the full path for a namespace's JSON file
    def file_path(namespace)
      File.join(base_dir, "#{namespace}.json")
    end

    # Resolve the base directory for memory storage.
    # Priority: explicit base_path > config.memory_path > {cwd}/.ruby-mana
    def base_dir
      return File.join(@base_path, "memory") if @base_path

      custom_path = Mana.config.memory_path
      return File.join(custom_path, "memory") if custom_path

      # Default fallback — project-local .ruby-mana directory
      File.join(Dir.pwd, ".ruby-mana")
    end
  end
end
