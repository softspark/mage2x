#!/usr/bin/env bash
# Release @softspark/mage2x. The only supported way to create a release tag.
#
#   npm run release -- X.Y.Z             gates, Linux run, pack smoke, tag, push, watch publish
#   npm run release -- X.Y.Z --dry-run   everything up to the tag; prints the rest
#   scripts/release.sh --gates-only      the gate alone (what the Linux container runs)
#
# GitHub Actions only publishes the tag; nothing there re-runs these checks, so
# a tag made by hand ships whatever was on the commit. See
# kb/procedures/sop-release.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

PKG="@softspark/mage2x"
GH_REPO="softspark/mage2x"
BRANCH="main"
LINUX_IMAGE="node:24"
VERBS="available context list exec shell logs restart forward"
RUNTIMES="docker podman kube"

die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# One gate per line on screen, full output in the log. A failure prints the
# tail so the cause is visible without opening the file.
LOG=""
run() {
  local name="$1"; shift
  printf '  %-44s ' "$name"
  printf '\n### %s\n$ %s\n' "$name" "$*" >>"$LOG"
  if "$@" >>"$LOG" 2>&1; then
    echo ok
  else
    echo FAILED
    printf -- '--- last 40 lines of %s\n' "$LOG"
    tail -n 40 "$LOG"
    exit 1
  fi
}

check_required_files() {
  local f missing=0
  for f in LICENSE NOTICE CHANGELOG.md SECURITY.md CODE_OF_CONDUCT.md README.md \
           .npmrc .github/CODEOWNERS .github/FUNDING.yml .github/dependabot.yml \
           kb/procedures/sop-pre-commit.md \
           kb/procedures/sop-release.md \
           kb/procedures/sop-post-release-testing.md; do
    [ -f "$f" ] || { echo "missing: $f"; missing=1; }
  done
  return "$missing"
}

# npm only attests packages published with public access, so a public publish
# without --provenance ships unsigned. Comments are stripped first: the
# workflow's own prose mentions both flags.
check_supply_chain() {
  local code
  code="$(sed 's/#.*//' .github/workflows/publish.yml)"
  printf '%s' "$code" | grep -q 'registry-url:.*registry\.npmjs\.org' || { echo "publish.yml does not target public npm"; return 1; }
  printf '%s' "$code" | grep -q -- '--provenance' || { echo "public publish without --provenance"; return 1; }
  printf '%s' "$code" | grep -q 'id-token: write' || { echo "--provenance needs id-token: write"; return 1; }
  grep -q 'ignore-scripts=true' .npmrc || { echo ".npmrc must set ignore-scripts=true"; return 1; }
}

zsh_parse() {
  local f
  for f in mage2x.plugin.zsh _mage2x lib/*.zsh dist/mage2x.plugin.zsh; do
    zsh -n "$f" || { echo "does not parse: $f"; return 1; }
  done
}

# Every adapter must implement the whole verb set. A half-written runtime fails
# the moment someone reaches for the missing verb, on a server, rather than here.
# Run against the checkout and against the single-file bundle, which has to be a
# working plugin on its own.
adapter_contract() {
  local plugin="$1"
  VERBS="$VERBS" RUNTIMES="$RUNTIMES" zsh -c '
    source "$1"
    (( $+functions[m2d] )) || { print "m2d missing"; exit 1 }
    missing=0
    for rt in ${=RUNTIMES}; do
      for v in ${=VERBS}; do
        (( $+functions[_m2x_${rt}_${v}] )) || { print "missing _m2x_${rt}_${v}"; missing=1 }
      done
    done
    exit $missing' zsh "$plugin"
}

gates() {
  run "shellcheck (npm run lint)"            npm run lint
  run "installer parses (npm run typecheck)" npm run typecheck
  run "dist/ matches sources (bundle --check)" ./scripts/bundle.sh --check
  run "zsh -n on every zsh source"           zsh_parse
  run "adapter contract (checkout)"          adapter_contract ./mage2x.plugin.zsh
  run "adapter contract (dist bundle)"       adapter_contract ./dist/mage2x.plugin.zsh
  run "test suite (npm test)"                npm test
  run "required files"                       check_required_files
  run "supply-chain gates"                   check_supply_chain
  # Summary only; a format change must not fail a green gate.
  grep -E '^[0-9]+ passed, [0-9]+ failed' "$LOG" | tail -n 1 | sed 's/^/  suite: /' || true
}

# The tarball the tag will publish, built here and started once. npm ships
# LICENSE on its own but never NOTICE; Apache-2.0 section 4(d) makes carrying it
# an obligation, so its absence blocks the release.
#
# `run` calls this in an `if`, where set -e does not apply: every step carries
# its own `|| return 1`.
pack_smoke() {
  local work tarball f dir
  work="$(mktemp -d)" || return 1
  tarball="$(npm pack --pack-destination "$work" | tail -n 1)" || return 1
  tar -tzf "$work/$tarball" | sed 's#^package/##' >"$work/entries.txt" || return 1
  cat "$work/entries.txt"
  for f in mage2x.plugin.zsh _mage2x lib/core.zsh lib/rt-cli.zsh lib/rt-kube.zsh \
           lib/catalog.zsh bin/mage2x-install.mjs dist/mage2x.plugin.zsh \
           LICENSE NOTICE; do
    grep -qx "$f" "$work/entries.txt" || { echo "missing from tarball: $f"; return 1; }
  done
  HOME="$work/home" npm install -g --prefix "$work/npm" --ignore-scripts "$work/$tarball" || return 1
  dir="$(HOME="$work/home" "$work/npm/bin/mage2x-install" path)" || return 1
  echo "mage2x-install path -> $dir"
  [ -f "$dir/mage2x.plugin.zsh" ] || { echo "installed package has no plugin at $dir"; return 1; }
  rm -rf "$work"
}

# Step 4 applies: the plugin and its adapters are zsh, the suite and the bundler
# are bash, and ShellCheck, zsh and coreutils differ between macOS and Linux.
#
# The repository is copied in as a tar stream of the files git knows about,
# never mounted, so nothing in the container can write back to the checkout.
linux_gates() {
  local f tar_flags=()
  tar --version | grep -q bsdtar && tar_flags=(--no-xattrs --no-mac-metadata)
  git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | COPYFILE_DISABLE=1 tar ${tar_flags[@]+"${tar_flags[@]}"} --null -T - -cf - \
    | docker run --rm -i "$LINUX_IMAGE" bash -euo pipefail -c '
        apt-get update -qq >/dev/null
        apt-get install -y -qq zsh shellcheck >/dev/null
        mkdir /work && tar -xf - -C /work && chown -R node:node /work
        cd /work && runuser -u node -- bash scripts/release.sh --gates-only'
}

watch_publish() {
  local version="$1" tag="$2" run_id="" i
  for i in $(seq 1 30); do
    run_id="$(gh run list --repo "$GH_REPO" --workflow publish.yml --branch "$tag" \
      --json databaseId --jq '.[0].databaseId // empty')"
    [ -n "$run_id" ] && break
    sleep 10
  done
  [ -n "$run_id" ] || die "no publish run appeared for $tag"
  gh run watch "$run_id" --repo "$GH_REPO" --exit-status || die "publish run $run_id failed"
  # A fresh version can 404 for a minute or two after publish succeeds.
  for i in $(seq 1 30); do
    [ "$(npm view "$PKG@$version" version 2>/dev/null)" = "$version" ] && break
    [ "$i" = 30 ] && die "$PKG@$version is not on the registry"
    sleep 10
  done
  gh release view "$tag" --repo "$GH_REPO" >/dev/null || die "no GitHub Release for $tag"
  echo "published: $PKG@$version, GitHub Release $tag"
}

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

VERSION="" DRY_RUN=0 GATES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --gates-only) GATES_ONLY=1 ;;
    -h|--help)    usage ;;
    -*)           die "unknown option: $arg" ;;
    *)            [ -z "$VERSION" ] || die "one version only"; VERSION="$arg" ;;
  esac
done

TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"

if [ "$GATES_ONLY" = 1 ]; then
  LOG="$TMP_ROOT/mage2x-gates.log"; : >"$LOG"
  step "Gates (log: $LOG)"
  gates
  exit 0
fi

[ -n "$VERSION" ] || usage
TAG="v$VERSION"
OUT="$TMP_ROOT/mage2x-release-$VERSION"
mkdir -p "$OUT"
LOG="$OUT/gates.log"; : >"$LOG"

step "1. Preconditions"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a semver X.Y.Z: $VERSION"
[ "$(git branch --show-current)" = "$BRANCH" ] || die "not on $BRANCH"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] || die "$BRANCH differs from origin/$BRANCH"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG exists locally"
! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || die "tag $TAG exists on origin"
echo "  $BRANCH at $(git rev-parse --short HEAD), clean, in sync; $TAG is free"

step "2. Version and notes"
[ "$(node -p "require('./package.json').version")" = "$VERSION" ] || die "package.json is not $VERSION"
grep -q "^# mage2x $VERSION " dist/mage2x.plugin.zsh || die "dist/mage2x.plugin.zsh is not built for $VERSION (npm run bundle)"
grep -q "^## v$VERSION " CHANGELOG.md || die "CHANGELOG.md has no '## v$VERSION' heading"
[ "$(git log -1 --format=%s)" = "chore: release v$VERSION" ] || die "HEAD is not 'chore: release v$VERSION'"
echo "  package.json, dist bundle, CHANGELOG.md and HEAD say $VERSION"

step "3. Gates (log: $LOG)"
gates

step "4. Linux run ($LINUX_IMAGE, log: $OUT/linux.log)"
if linux_gates >"$OUT/linux.log" 2>&1; then
  grep -E '^  suite:' "$OUT/linux.log" | tail -n 1 | sed 's/^ */  linux /' || true
else
  tail -n 40 "$OUT/linux.log"; die "Linux gate failed"
fi

step "5. Build and smoke"
run "npm pack + installer smoke" pack_smoke

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run: would now"
  echo "  git tag $TAG                       # on $(git rev-parse --short HEAD)"
  echo "  git push origin $BRANCH"
  echo "  git push origin refs/tags/$TAG"
  echo "  gh run watch <publish.yml run for $TAG>; npm view $PKG@$VERSION; gh release view $TAG"
  exit 0
fi

step "6. Tag and push"
git tag "$TAG"
[ "$(git rev-list -n 1 "$TAG")" = "$(git rev-parse HEAD)" ] || die "$TAG does not point at HEAD"
[ "$(git log -1 --format=%s "$TAG")" = "chore: release v$VERSION" ] || die "$TAG is not on the release commit"
git push origin "$BRANCH"
git push origin "refs/tags/$TAG"

step "7. Watch publish"
watch_publish "$VERSION" "$TAG"
