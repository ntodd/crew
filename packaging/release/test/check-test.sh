#!/bin/sh
# Tests packaging/release/check.sh, the release workflow's first job,
# against made-up repos: the tag's form, every mix.exs version, the
# release key, and the supply-chain verdicts in the release notes.
#
#   packaging/release/test/check-test.sh
#
# Needs elixir (to read the mix.exs files) and openssl. ELIXIR may name
# another command that runs elixir.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
check=$repo/packaging/release/check.sh

# A key that isn't the test key, and its fingerprint as
# CrewProtocol.Auth.fingerprint/1 writes it.
key=Kk68lzZ0efwOdTKvVKhIPGF8ezi70kY7YV9WoFUMryA=
fingerprint=SHA256:6bdibIsLV/zTQTX1eOBLc3+arwGj5TP+fHDxcaPbWa0
test_key=$(grep -v '^#' "$repo/images/guest/keys/test-signing.pub" | tr -d ' \n')

pass=0 fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok    %s\n' "$1"
}
not_ok() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1"
  sed 's/^/      /' "$T/out"
}

T=""
# A repo that passes for v1.2.3: two projects that take CREW_VERSION, the
# test key, the release key committed and in the variable, and notes
# with a clean review.
new_repo() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/crew-check-test.XXXXXX")
  R=$T/repo
  for app in alpha beta; do
    mkdir -p "$R/apps/$app"
    cat > "$R/apps/$app/mix.exs" << EOF
defmodule Check${app}.MixProject do
  use Mix.Project
  @version System.get_env("CREW_VERSION", "0.1.0")
  def project, do: [app: :$app, version: @version]
end
EOF
  done
  mkdir -p "$R/apps/alpha/deps/dep" "$R/images/guest/keys" "$R/packaging/release" "$R/docs/releases"
  printf 'defmodule Dep.MixProject do\n  use Mix.Project\n  def project, do: [app: :dep, version: "9.9.9"]\nend\n' \
    > "$R/apps/alpha/deps/dep/mix.exs"
  cp "$repo/images/guest/keys/test-signing.pub" "$R/images/guest/keys/"
  printf '# the release key\n%s\n' "$key" > "$R/packaging/release/release-key.pub"
  notes "| actions/runner | 2.338.2 | 2.339.0 | clean | Only the runner's own code changed. |"
  CREW_RELEASE_PUBLIC_KEY=$key
}

notes() {
  {
    printf '# Crew 1.2.3\n\nWhat changed.\n\n## Supply-chain review\n\n'
    printf '| Bump | From | To | Verdict | Notes |\n|---|---|---|---|---|\n'
    for row in "$@"; do printf '%s\n' "$row"; done
    printf '\n## Upgrading\n\n| a | b | suspicious |\n'
  } > "$R/docs/releases/v1.2.3.md"
}

# run TAG: the check, its output in $T/out and $T/github_output.
run() {
  : > "$T/github_output"
  CREW_RELEASE_ROOT=$R CREW_RELEASE_PUBLIC_KEY=$CREW_RELEASE_PUBLIC_KEY GITHUB_OUTPUT=$T/github_output \
    "$check" "$1" > "$T/out" 2>&1
}
passes() {
  if run "$2"; then ok "$1"; else not_ok "$1"; fi
}
fails() {
  desc=$1 tag=$2 says=$3
  if run "$tag"; then
    not_ok "$desc (passed)"
  elif ! grep -qF -- "$says" "$T/out"; then
    not_ok "$desc (didn't say \"$says\")"
  else
    ok "$desc"
  fi
}

new_repo
passes "a good release passes" v1.2.3
if grep -qx version=1.2.3 "$T/github_output" && grep -qx "fingerprint=$fingerprint" "$T/github_output"; then
  ok "and gives the version and the key's fingerprint"
else
  not_ok "and gives the version and the key's fingerprint"
fi

for tag in 1.2.3 v1.2 v1.2.3.4 v01.2.3 v1.2.3-rc.1 v10000.0.0 "v1.2.3 "; do
  new_repo
  fails "the tag [$tag] isn't vX.Y.Z" "$tag" "isn't vX.Y.Z"
done

new_repo
sed -i.bak 's/@version System.get_env("CREW_VERSION", "0.1.0")/@version "0.1.0"/' "$R/apps/beta/mix.exs"
fails "a mix.exs that doesn't take CREW_VERSION" v1.2.3 "apps/beta/mix.exs is 0.1.0"

new_repo
rm "$R/packaging/release/release-key.pub"
fails "no committed release key" v1.2.3 "packaging/release/release-key.pub"

new_repo
printf '%s\n' "$test_key" > "$R/packaging/release/release-key.pub"
CREW_RELEASE_PUBLIC_KEY=$test_key
fails "the test key" v1.2.3 "test key"

new_repo
printf 'not a key\n' > "$R/packaging/release/release-key.pub"
fails "a release key that isn't one" v1.2.3 "32-byte"

new_repo
CREW_RELEASE_PUBLIC_KEY=""
fails "the variable unset" v1.2.3 "CREW_RELEASE_PUBLIC_KEY"

new_repo
CREW_RELEASE_PUBLIC_KEY=$test_key
fails "the variable isn't the committed key" v1.2.3 "isn't the key in"

new_repo
rm "$R/docs/releases/v1.2.3.md"
fails "no release notes" v1.2.3 "docs/releases/v1.2.3.md"

new_repo
printf '# Crew 1.2.3\n\nNothing about bumps.\n' > "$R/docs/releases/v1.2.3.md"
fails "notes without the review" v1.2.3 "Supply-chain review"

new_repo
notes
fails "a review with no rows" v1.2.3 "no verdicts"

new_repo
notes "| Firecracker | 1.13.1 | 1.14.0 | clean | |" \
  "| Flatcar | 4459.2.1 | 4593.1.0 | suspicious | A new download at boot. |"
fails "a suspicious verdict blocks the release" v1.2.3 "Flatcar: suspicious"

new_repo
notes "| Go modules | - | - | fine | |"
fails "a verdict that isn't one of the three" v1.2.3 "Go modules: fine"

new_repo
notes "| Go modules | - | - | can't tell | Upstream's history was rewritten. |" \
  "| vfkit | 0.6.1 | 0.6.2 | Clean | |"
passes "can't tell and clean pass (any case)" v1.2.3

new_repo
printf '# Crew 1.2.3\n\n## Supply-chain review\n\nNo bumps.\n' > "$R/docs/releases/v1.2.3.md"
passes "no bumps passes" v1.2.3

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
