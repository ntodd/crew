# Check the caller's permission ceiling before the image build runs checkout code.
require "yaml"

def jobs(workflow)
  YAML.load_file(File.join(__dir__, "../workflows/#{workflow}.yml")).fetch("jobs")
end

image = jobs("guest-image")
writers = image.values.select { |job| job.dig("permissions", "packages") == "write" }
abort "cache writer must be restricted to main" unless writers.size == 1 &&
  writers.first["if"] == "github.ref == 'refs/heads/main' && github.event_name != 'pull_request'"
abort "release must use read-only image build" unless jobs("release").fetch("guest").dig("permissions", "packages") == "read"
