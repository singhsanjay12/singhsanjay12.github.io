# Runs all test suites in a single process.
# Usage (from repo root, after jekyll build):
#   ruby tests/run_all.rb

Dir[File.join(__dir__, "*_test.rb")].sort.each { |f| require f }
