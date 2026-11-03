defmodule CrewGuest.EnvFileTest do
  use ExUnit.Case, async: true

  alias CrewGuest.EnvFile

  test "merge/2 replaces the given keys and keeps everything else" do
    existing = ~s(PATH="/usr/bin"\nSSL_CERT_FILE=/old\n# a comment\n\nLANG=C.UTF-8)

    assert EnvFile.merge(existing, [{"SSL_CERT_FILE", "/new"}, {"CURL_CA_BUNDLE", "/b"}]) ==
             ~s(PATH="/usr/bin"\n# a comment\n\nLANG=C.UTF-8\nSSL_CERT_FILE=/new\nCURL_CA_BUNDLE=/b\n)
  end

  test "merge/2 into nothing" do
    assert EnvFile.merge("", [{"A", "1"}]) == "A=1\n"
  end

  test "shell/1 quotes values for sh" do
    assert EnvFile.shell([{"A", "it's"}, {"B", "x y"}]) == ~s(A='it'\\''s'\nB='x y'\n)
  end
end
