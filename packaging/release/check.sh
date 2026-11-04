#!/bin/sh
# The release workflow's first job (docs/crew_spec.md §20.1, §20.4),
# before anything is built:
#
#   - the tag is vX.Y.Z, in the form crew-update takes (at most four
#     digits a field, no leading zeros);
#   - every mix.exs in the repo, read with CREW_VERSION set to it, is
#     that version, so no project ships under another;
#   - the release key's public half is committed in
#     packaging/release/release-key.pub, isn't the development test key,
#     and is the CREW_RELEASE_PUBLIC_KEY repository variable, which the
#     control plane's images are built with (the sign job checks the
#     secret against the same file);
#   - docs/releases/<tag>.md has a "## Supply-chain review" whose every
#     verdict is clean or can't tell (a suspicious one blocks the
#     release), or says "No bumps."
#
#   CREW_RELEASE_PUBLIC_KEY=... packaging/release/check.sh v1.2.3
#
# Writes version= and fingerprint= (the key's, as the release notes and
# the Deployment page show it) to $GITHUB_OUTPUT when that's set.
# CREW_RELEASE_ROOT points it at another repo (its tests); ELIXIR names
# the command that runs elixir.
set -eu

root=${CREW_RELEASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
tag=${1:?usage: check.sh vX.Y.Z}
problems=0
problem() {
  echo "::error::$*"
  problems=$((problems + 1))
}
key_lines() { grep -v '^[[:space:]]*#' | tr -d ' \t\r' | grep -v '^$' || true; }

# -- the tag ---------------------------------------------------------------------

n='(0|[1-9][0-9]{0,3})'
if ! printf '%s\n' "$tag" | grep -Eqx "v$n\.$n\.$n"; then
  echo "::error::$tag isn't vX.Y.Z"
  exit 1
fi
version=${tag#v}

# -- every mix.exs ---------------------------------------------------------------

mix_files=$(cd "$root" && find . -name mix.exs -not -path '*/deps/*' -not -path '*/_build/*' \
  -not -path '*/node_modules/*' | sed 's|^\./||' | sort)
[ -n "$mix_files" ] || problem "no mix.exs under $root"
# shellcheck disable=SC2086 # the paths have no spaces
versions=$(cd "$root" && CREW_VERSION=$version ${ELIXIR:-elixir} -e '
  Mix.start()
  for path <- System.argv() do
    app = :"release_check_#{System.unique_integer([:positive])}"
    Mix.Project.in_project(app, Path.dirname(path), fn _ ->
      IO.puts("#{path} #{Mix.Project.config()[:version]}")
    end)
  end' -- $mix_files) || problem "couldn't read the mix.exs files"
for f in $mix_files; do
  v=$(printf '%s\n' "$versions" | sed -n "s|^$f ||p")
  [ "$v" = "$version" ] || problem "$f is ${v:-unreadable}, not $version: every mix.exs takes CREW_VERSION"
done

# -- the release key -------------------------------------------------------------

key_file=$root/packaging/release/release-key.pub
test_key=$(key_lines < "$root/images/guest/keys/test-signing.pub")
key=""
fingerprint=""
if [ ! -f "$key_file" ]; then
  problem "commit the release key's public half to packaging/release/release-key.pub (docs/releasing.md)"
else
  key=$(key_lines < "$key_file")
  bytes=$(printf '%s' "$key" | openssl base64 -d -A 2> /dev/null | wc -c | tr -d ' ')
  if [ "$bytes" != 32 ]; then
    problem "packaging/release/release-key.pub isn't a base64 32-byte ed25519 public key"
  elif [ "$key" = "$test_key" ]; then
    problem "packaging/release/release-key.pub is the development test key"
  else
    fingerprint=SHA256:$(printf '%s' "$key" | openssl base64 -d -A | openssl dgst -sha256 -binary |
      openssl base64 -A | tr -d '=')
  fi
fi
variable=$(printf '%s\n' "${CREW_RELEASE_PUBLIC_KEY:-}" | key_lines)
if [ -z "$variable" ]; then
  problem "set the CREW_RELEASE_PUBLIC_KEY repository variable to packaging/release/release-key.pub's key"
elif [ -n "$key" ] && [ "$variable" != "$key" ]; then
  problem "the CREW_RELEASE_PUBLIC_KEY variable isn't the key in packaging/release/release-key.pub"
fi

# -- the supply-chain review -----------------------------------------------------

notes=$root/docs/releases/$tag.md
if [ ! -f "$notes" ]; then
  problem "write docs/releases/$tag.md with its supply-chain review (docs/releasing.md)"
else
  # One "<verdict>|<bump>" line per row of the review's table (read by
  # its Verdict column), "none|" for "No bumps.", and nothing at all
  # without the section.
  verdicts=$(awk '
    $0 == "## Supply-chain review" { inside = 1; found = 1; next }
    inside && /^## / { inside = 0 }
    inside && /^No bumps\.?[[:space:]]*$/ { print "none|"; next }
    inside && /^[[:space:]]*\|/ {
      n = split($0, cell, "|")
      for (i = 2; i < n; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell[i])
      if (!col) { for (i = 2; i < n; i++) if (tolower(cell[i]) == "verdict") col = i; next }
      if (cell[2] ~ /^:?-+:?$/) next
      print tolower(cell[col]) "|" cell[2]
    }
    END { if (!found) print "missing|" }' "$notes")
  case $verdicts in
    "missing|")
      problem "docs/releases/$tag.md has no \"## Supply-chain review\" section"
      ;;
    "")
      problem "docs/releases/$tag.md's supply-chain review has no verdicts (a table with a Verdict column, or \"No bumps.\")"
      ;;
    *)
      printf '%s\n' "$verdicts" | {
        bad=0
        while IFS='|' read -r verdict bump; do
          case $verdict in
            clean | "can't tell" | "can’t tell" | none) ;;
            suspicious)
              echo "::error::$bump: suspicious. A suspicious verdict blocks the bump, and so the release."
              bad=1
              ;;
            *)
              echo "::error::$bump: $verdict isn't a verdict (clean, suspicious or can't tell)"
              bad=1
              ;;
          esac
        done
        exit $bad
      } || problems=$((problems + 1))
      ;;
  esac
fi

[ "$problems" -eq 0 ] || exit 1
echo "release $version: tag, versions, release key ($fingerprint) and supply-chain review check out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'version=%s\nfingerprint=%s\n' "$version" "$fingerprint" >> "$GITHUB_OUTPUT"
fi
