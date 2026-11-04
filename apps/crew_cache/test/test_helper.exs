# Tests that need a tool run only where it's installed: :go (crypto/x509
# checks the CA chain, and Go's TLS client the listener) and :openssl.
missing = for tool <- [:go, :openssl], System.find_executable("#{tool}") == nil, do: tool
ExUnit.start(capture_log: true, exclude: missing)
