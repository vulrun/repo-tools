#!/usr/bin/env bash
# Runs ghrepo, glrepo and install.sh against fake gh and glab commands
# (tests/stubs) backed by local bare repos. No network or accounts needed.
#
#   bash tests/run.sh
#
# Checks are passed to t() as single-quoted strings and run with eval.
# shellcheck disable=SC2016,SC2034,SC2001
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolated home, git config and PATH. The stubs are called through
# wrappers so the tests work even if the files lost their executable bit.
export HOME="$WORK/home"
export STUB_STATE="$WORK/state"
export GL_HOST="gitlab.test"
export GIT_CONFIG_NOSYSTEM=1
unset GITLAB_TOKEN GL_TOKEN GITLAB_HOST STUB_GH_SCOPES STUB_GL_TOKEN XDG_DATA_HOME
mkdir -p "$HOME" "$WORK/stubbin"
for s in gh glab; do
  printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$ROOT/tests/stubs/$s" > "$WORK/stubbin/$s"
  chmod +x "$WORK/stubbin/$s"
done
export PATH="$WORK/stubbin:$PATH"

git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global url."file://$STUB_STATE/github/".insteadOf "https://github.com/"
git config --global url."file://$STUB_STATE/gitlab/".insteadOf "https://gitlab.test/"
# A stored-password helper the tools must ignore (local file:// pushes never ask).
git config --global credential.helper '!f() { echo username=wrong; echo password=WRONG; }; f'

ghrepo() { bash "$ROOT/bin/ghrepo" "$@"; }
glrepo() { bash "$ROOT/bin/glrepo" "$@"; }

# ---------- assertions ----------

PASS=0; FAILS=0; OUT=""; RC=0
run() { OUT="$("$@" 2>&1)"; RC=$?; }
has()   { grep -qF -- "$1" <<< "$OUT"; }
rc_is() { [ "$RC" -eq "$1" ]; }
t() {
  if eval "$2"; then
    PASS=$((PASS + 1)); echo "  ok    $1"
  else
    FAILS=$((FAILS + 1)); echo "  FAIL  $1"; sed 's/^/        | /' <<< "$OUT"
  fi
}

# ---------- fixtures ----------

# A source repo with two branches, an annotated tag and a workflow file.
FIXTURE="$WORK/fixture"
git init -q "$FIXTURE"
(
  cd "$FIXTURE" || exit 1
  mkdir -p .github/workflows
  echo "on: push" > .github/workflows/ci.yml
  git add -A && git commit -qm "first"
  echo two > file && git add -A && git commit -qm "second"
  git tag -a v1 -m "v1"
  git checkout -qb feature && echo f > feature && git add -A && git commit -qm "feature"
  git checkout -q main
)
# An unrelated repo, for "destination has commits not in the source".
FOREIGN="$WORK/foreign"
git init -q "$FOREIGN"
(cd "$FOREIGN" && echo x > x && git add -A && git commit -qm "unrelated")

ALL_REFS=('refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*')

reset() {
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE/github" "$STUB_STATE/gitlab"
  : > "$STUB_STATE/calls.log"
}
refs()      { git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort; }
same_refs() { [ "$(refs "$1")" = "$(refs "$2")" ]; }

# GitHub side
GHS() { echo "$STUB_STATE/github/$1.git"; }
gh_org() { mkdir -p "$STUB_STATE/github/$1"; }
gh_repo() {   # gh_repo <org/name> <VIS> [refspec ...]   (no refspec = all refs)
  local r="$1" vis="$2"; shift 2
  git init -q --bare "$(GHS "$r")"
  printf 'vis=%s\narchived=false\n' "$vis" > "$STUB_STATE/github/$r.meta"
  if [ "$#" -eq 0 ]; then set -- "${ALL_REFS[@]}"; fi
  [ "$1" = none ] || git -C "$FIXTURE" push -q "$(GHS "$r")" "$@"
}
gh_meta() { sed -n "s/^$2=//p" "$STUB_STATE/github/$1.meta"; }

# GitLab side
GLS() { echo "$STUB_STATE/gitlab/$1.git"; }
gl_group() { mkdir -p "$STUB_STATE/gitlab/$1"; echo "$2" > "$STUB_STATE/gitlab/$1/.group"; }
gl_project() {   # gl_project <path> <vis> [refspec ...]   (no refspec = all refs)
  local p="$1" vis="$2"; shift 2
  git init -q --bare "$(GLS "$p")"
  git -C "$(GLS "$p")" config receive.advertisePushOptions true
  printf 'id=%s\nvis=%s\narchived=false\n' "$RANDOM" "$vis" > "$STUB_STATE/gitlab/$p.meta"
  if [ "$#" -eq 0 ]; then set -- "${ALL_REFS[@]}"; fi
  [ "$1" = none ] || git -C "$FIXTURE" push -q "$(GLS "$p")" "$@"
}
gl_meta() { sed -n "s/^$2=//p" "$STUB_STATE/gitlab/$1.meta"; }

# =====================================================================
echo "ghrepo: help and arguments"
reset
run ghrepo;                   t "no arguments shows help"            'rc_is 0 && has USAGE'
run ghrepo --version;         t "--version prints the version"       'rc_is 0 && has "ghrepo 1."'
for c in copy archive transfer rename; do
  run ghrepo "$c" --help;     t "$c --help works without gh login"   'rc_is 0 && has USAGE'
done
run ghrepo frobnicate;        t "unknown command fails"               'rc_is 1 && has "Unknown command"'
run ghrepo copy old/x;        t "copy with one argument shows usage"  'rc_is 1 && has USAGE'

echo "ghrepo: copy"
reset; gh_org old; gh_org new
gh_repo old/website PRIVATE
run ghrepo copy old/website new
t "copies every branch and tag"          'rc_is 0 && same_refs "$(GHS old/website)" "$(GHS new/website)"'
t "keeps private visibility"             '[ "$(gh_meta new/website vis)" = PRIVATE ]'

gh_repo old/site PUBLIC
run ghrepo copy old/site new
t "keeps public visibility"              'rc_is 0 && [ "$(gh_meta new/site vis)" = PUBLIC ]'

gh_repo old/a PRIVATE; gh_repo old/b PRIVATE; gh_repo old/c PRIVATE; gh_repo old/d PRIVATE
run ghrepo copy old/a old/b new
t "several sources as separate args"     'rc_is 0 && [ -d "$(GHS new/a)" ] && [ -d "$(GHS new/b)" ]'
run ghrepo copy "old/c,d" new
t "several sources as a comma list"      'rc_is 0 && [ -d "$(GHS new/c)" ] && [ -d "$(GHS new/d)" ]'

run ghrepo copy old/website new/website-v2
t "org/new-name makes a renamed copy"    'rc_is 0 && same_refs "$(GHS old/website)" "$(GHS new/website-v2)"'

run ghrepo copy old/a old/b new/renamed
t "several sources refuse org/new-name"  'rc_is 1 && has "org name only"'

gh_repo old/e PRIVATE; gh_repo new/e PRIVATE none
run ghrepo copy old/e new
t "reuses an existing empty repo"        'rc_is 0 && has "reusing" && same_refs "$(GHS old/e)" "$(GHS new/e)"'

gh_repo old/p PRIVATE; gh_repo new/p PRIVATE "main~1:refs/heads/main"
run ghrepo copy old/p new
t "resumes a partial copy"               'rc_is 0 && has "Resuming" && same_refs "$(GHS old/p)" "$(GHS new/p)"'

gh_repo old/f PRIVATE; gh_repo new/f PRIVATE none
git -C "$FOREIGN" push -q "$(GHS new/f)" main
before="$(refs "$(GHS new/f)")"
run ghrepo copy old/f new
t "skips a repo with foreign commits"    'rc_is 0 && has "not touching" && [ "$(refs "$(GHS new/f)")" = "$before" ]'

run ghrepo copy old/nope new
t "skips a missing source"               'rc_is 0 && has "not found"'

run ghrepo copy old/website ghost
t "reports a failed create"              'rc_is 1 && has "could not create" && has "1 failed"'

run ghrepo copy old/website old
t "skips copying a repo onto itself"     'rc_is 0 && has "same"'

run ghrepo copy website new
t "reports a source without an org"      'rc_is 0 && has "not a valid org/repo"'

gh_repo old/w PRIVATE
run env STUB_GH_SCOPES="'repo', 'gist'" bash "$ROOT/bin/ghrepo" copy old/w new
t "stops early without workflow scope"   'rc_is 1 && has "workflow scope" && [ ! -e "$(GHS new/w)" ]'

t "git gets the gh login, no prompt" \
  '[ "$( (source "$ROOT/bin/ghrepo" --version >/dev/null; printf "protocol=https\nhost=github.com\n\n" | ghgit credential fill) | grep "^password=")" = "password=gho_stubtoken" ]'

echo "ghrepo: archive, transfer, rename"
reset; gh_org old; gh_org new; gh_org arch
gh_repo old/a PRIVATE; gh_repo old/b PRIVATE; gh_repo old/c PRIVATE; gh_repo arch/c PRIVATE

run ghrepo archive old/a old/nope
t "archives a repo, skips a missing one" 'rc_is 0 && [ "$(gh_meta old/a archived)" = true ] && has "not found"'
run ghrepo archive old/a
t "skips an already archived repo"       'rc_is 0 && has "already archived"'

run ghrepo transfer "old/{a,b}" arch
t "transfers with a quoted brace list"   'rc_is 0 && [ -d "$(GHS arch/a)" ] && [ -d "$(GHS arch/b)" ] && [ ! -e "$(GHS old/a)" ]'
run ghrepo transfer old/c arch
t "skips a transfer onto a taken name"   'rc_is 0 && has "already exists" && [ -d "$(GHS old/c)" ]'
run ghrepo transfer old/c arch/x
t "transfer refuses org/repo as target"  'rc_is 1 && has "org name only"'

gh_repo new/website PRIVATE; gh_repo new/taken PRIVATE
run ghrepo rename new/website web2
t "renames a repo"                       'rc_is 0 && [ -d "$(GHS new/web2)" ] && [ ! -e "$(GHS new/website)" ]'
run ghrepo rename new/web2 taken
t "rename refuses a taken name"          'rc_is 1 && has "already exists" && [ -d "$(GHS new/web2)" ]'
run ghrepo rename new/web2 web2
t "rename refuses the same name"         'rc_is 1 && has "same"'
run ghrepo rename new/web2 other/web3
t "rename refuses a new org"             'rc_is 1 && has "use transfer"'

# =====================================================================
echo "glrepo: help and arguments"
reset
run glrepo;                   t "no arguments shows help"            'rc_is 0 && has USAGE'
run glrepo --version;         t "--version prints the version"       'rc_is 0 && has "glrepo 1."'
for c in copy archive transfer rename; do
  run glrepo "$c" --help;     t "$c --help works without glab login" 'rc_is 0 && has USAGE'
done
run glrepo frobnicate;        t "unknown command fails"               'rc_is 1 && has "Unknown command"'

echo "glrepo: copy"
reset; gl_group old 10; gl_group new 20; gl_group new/backend 21
gl_project old/website private
run glrepo copy old/website new
t "copies every branch and tag"          'rc_is 0 && same_refs "$(GLS old/website)" "$(GLS new/website)"'
t "keeps private visibility"             '[ "$(gl_meta new/website vis)" = private ]'
t "pushes with ci.skip"                  'grep -qx ci.skip "$STUB_STATE/pushopts.log"'

gl_project old/a internal; gl_project old/b private; gl_project old/c private; gl_project old/d private
run glrepo copy old/a old/b new/backend
t "copies several into a subgroup"       'rc_is 0 && [ -d "$(GLS new/backend/a)" ] && [ -d "$(GLS new/backend/b)" ]'
t "keeps internal visibility"            '[ "$(gl_meta new/backend/a vis)" = internal ]'
run glrepo copy "old/c,d" new
t "several sources as a comma list"      'rc_is 0 && [ -d "$(GLS new/c)" ] && [ -d "$(GLS new/d)" ]'

run glrepo copy old/website new/website-v2
t "group/new-name makes a renamed copy"  'rc_is 0 && same_refs "$(GLS old/website)" "$(GLS new/website-v2)"'
run glrepo copy old/a old/b new/renamed
t "several sources need a real group"    'rc_is 1 && has "existing group"'
run glrepo copy old/website ghost
t "fails on a missing group"             'rc_is 1 && has "not found"'

gl_project old/e private; gl_project new/e private none
run glrepo copy old/e new
t "reuses an existing empty project"     'rc_is 0 && has "reusing" && same_refs "$(GLS old/e)" "$(GLS new/e)"'

gl_project old/p private; gl_project new/p private "main~1:refs/heads/main"
run glrepo copy old/p new
t "resumes a partial copy"               'rc_is 0 && has "Resuming" && same_refs "$(GLS old/p)" "$(GLS new/p)"'

gl_project old/f private; gl_project new/f private none
git -C "$FOREIGN" push -q "$(GLS new/f)" main
before="$(refs "$(GLS new/f)")"
run glrepo copy old/f new
t "skips a project with foreign commits" 'rc_is 0 && has "not touching" && [ "$(refs "$(GLS new/f)")" = "$before" ]'

gl_project old/t private
run env STUB_GL_TOKEN="" bash "$ROOT/bin/glrepo" copy old/t new
t "stops without a token"                'rc_is 1 && has "GitLab token" && [ ! -e "$(GLS new/t)" ]'
run env STUB_GL_TOKEN="" GITLAB_TOKEN="glpat-env" bash "$ROOT/bin/glrepo" copy old/t new
t "uses GITLAB_TOKEN when set"           'rc_is 0 && [ -d "$(GLS new/t)" ]'

t "git gets the glab token, no prompt" \
  '[ "$( (source "$ROOT/bin/glrepo" --version >/dev/null; GLREPO_TOKEN=glpat-abc; printf "protocol=https\nhost=gitlab.test\n\n" | ggit credential fill) | grep "^password=")" = "password=glpat-abc" ]'

echo "glrepo: archive, transfer, rename"
reset; gl_group old 10; gl_group new 20; gl_group arch 30; gl_group arch/legacy 31
gl_project old/a private; gl_project old/b private; gl_project old/c private; gl_project arch/c private

run glrepo archive old/a old/nope
t "archives a project, skips a missing one" 'rc_is 0 && [ "$(gl_meta old/a archived)" = true ] && has "not found"'
run glrepo archive old/a
t "skips an already archived project"    'rc_is 0 && has "already archived"'

run glrepo transfer "old/{a,b}" arch/legacy
t "transfers into a subgroup"            'rc_is 0 && [ -d "$(GLS arch/legacy/a)" ] && [ -d "$(GLS arch/legacy/b)" ] && [ ! -e "$(GLS old/a)" ]'
run glrepo transfer old/c arch
t "skips a transfer onto a taken name"   'rc_is 0 && has "already exists" && [ -d "$(GLS old/c)" ]'
run glrepo transfer old/c ghost
t "transfer fails on a missing group"    'rc_is 1 && has "not found"'

gl_project new/website private; gl_project new/taken private
run glrepo rename new/website web2
t "renames a project"                    'rc_is 0 && [ -d "$(GLS new/web2)" ] && [ ! -e "$(GLS new/website)" ]'
run glrepo rename new/web2 taken
t "rename refuses a taken name"          'rc_is 1 && has "already exists"'

# =====================================================================
echo "install.sh"

H1="$WORK/h1"; mkdir -p "$H1"
run env HOME="$H1" bash "$ROOT/install.sh"
t "installs every tool from a clone"     'rc_is 0 && [ -x "$H1/.local/bin/ghrepo" ] && [ -x "$H1/.local/bin/glrepo" ]'
t "installed tool runs"                  '"$H1/.local/bin/ghrepo" --version | grep -q "^ghrepo 1."'
t "adds the PATH line to .bashrc"        'grep -qF "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$H1/.bashrc"'
run env HOME="$H1" bash "$ROOT/install.sh"
t "running again doesn't repeat it"      '[ "$(grep -cF "/.local/bin:" "$H1/.bashrc")" -eq 1 ]'
run env HOME="$H1" bash "$ROOT/install.sh" --uninstall
t "uninstall removes the tools"          'rc_is 0 && [ ! -e "$H1/.local/bin/ghrepo" ] && [ ! -e "$H1/.local/bin/glrepo" ]'

H2="$WORK/h2"; mkdir -p "$H2" "$WORK/pkg"
cp -R "$ROOT" "$WORK/pkg/repo-tools-main"
tar -czf "$WORK/pkg.tar.gz" -C "$WORK/pkg" repo-tools-main
run bash -c "cat '$ROOT/install.sh' | HOME='$H2' ARCHIVE_URL='file://$WORK/pkg.tar.gz' bash"
t "curl | bash mode installs from a download" 'rc_is 0 && [ -x "$H2/.local/bin/ghrepo" ] && [ -x "$H2/.local/bin/glrepo" ]'
run bash -c "cat '$ROOT/install.sh' | HOME='$H2' bash"
t "curl | bash mode needs REPO set"      'rc_is 1 && has "REPO isn'"'"'t set"'

# =====================================================================
echo
echo "$PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
