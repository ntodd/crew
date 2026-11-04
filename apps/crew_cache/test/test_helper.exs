# Tests that need a tool run only where it's installed: :go (crypto/x509
# checks the CA chain), :openssl, and :crane (a real client through the
# cache).
missing = for tool <- [:go, :openssl, :crane], System.find_executable("#{tool}") == nil, do: tool
ExUnit.start(capture_log: true, exclude: missing)
