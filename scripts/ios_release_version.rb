#!/usr/bin/env ruby

require "json"
require "optparse"

PROJECT_PATH = File.expand_path("../ios/project.yml", __dir__)
PACKAGE_PATH = File.expand_path("../package.json", __dir__)

def read_project
  File.read(PROJECT_PATH)
end

def parse_release_version(content)
  marketing_versions = content.scan(/^\s*MARKETING_VERSION:\s*(.+)\s*$/)
  build_numbers = content.scan(/^\s*CURRENT_PROJECT_VERSION:\s*(.+)\s*$/)

  raise "Unable to find MARKETING_VERSION in #{PROJECT_PATH}" if marketing_versions.empty?
  raise "Unable to find CURRENT_PROJECT_VERSION in #{PROJECT_PATH}" if build_numbers.empty?

  marketing_version = marketing_versions.first.first.strip.delete_prefix('"').delete_suffix('"')
  build_number = Integer(build_numbers.first.first.strip.delete_prefix('"').delete_suffix('"'))

  {
    "marketing_version" => marketing_version,
    "build_number" => build_number
  }
end

def write_project(version: nil, build: nil)
  content = read_project

  if version
    content, replacements = content.gsubn(/^(\s*MARKETING_VERSION:\s*).+$/, "\\1#{version}")
    raise "Expected to update MARKETING_VERSION in ios/project.yml" if replacements.zero?
  end

  if build
    content, replacements = content.gsubn(/^(\s*CURRENT_PROJECT_VERSION:\s*).+$/, "\\1#{build}")
    raise "Expected to update CURRENT_PROJECT_VERSION in ios/project.yml" if replacements.zero?
  end

  File.write(PROJECT_PATH, content)
end

def sync_package_version(version)
  content = JSON.parse(File.read(PACKAGE_PATH))
  content["version"] = version
  File.write(PACKAGE_PATH, JSON.pretty_generate(content) + "\n")
end

command = ARGV.shift

case command
when "show"
  options = { json: false }
  OptionParser.new do |parser|
    parser.on("--json", "Emit JSON output") { options[:json] = true }
  end.parse!(ARGV)

  release = parse_release_version(read_project)
  if options[:json]
    puts JSON.generate(release)
  else
    puts "MARKETING_VERSION=#{release.fetch("marketing_version")}"
    puts "CURRENT_PROJECT_VERSION=#{release.fetch("build_number")}"
  end
when "set"
  options = { sync_package_version: false }

  OptionParser.new do |parser|
    parser.on("--version VERSION", "Set MARKETING_VERSION") { |value| options[:version] = value }
    parser.on("--build BUILD", Integer, "Set CURRENT_PROJECT_VERSION") { |value| options[:build] = value }
    parser.on("--bump-build", "Increment CURRENT_PROJECT_VERSION by one") { options[:bump_build] = true }
    parser.on("--sync-package-version", "Also update package.json version") { options[:sync_package_version] = true }
  end.parse!(ARGV)

  raise "Pass --version, --build, or --bump-build" unless options[:version] || options[:build] || options[:bump_build]

  current = parse_release_version(read_project)
  build = options[:build]
  build = current.fetch("build_number") + 1 if build.nil? && options[:bump_build]
  raise "Build number must be positive" if build && build <= 0

  version = options[:version]
  write_project(version: version, build: build)
  sync_package_version(version) if options[:sync_package_version] && version

  updated = parse_release_version(read_project)
  puts "Updated #{PROJECT_PATH} to #{updated.fetch("marketing_version")} (#{updated.fetch("build_number")})"
else
  warn "Usage:"
  warn "  ruby scripts/ios_release_version.rb show [--json]"
  warn "  ruby scripts/ios_release_version.rb set [--version VERSION] [--build BUILD|--bump-build] [--sync-package-version]"
  exit 1
end
