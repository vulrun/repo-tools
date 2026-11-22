#!/usr/bin/env bash
# install.sh: installs or updates every tool in bin/ (ghrepo, glrepo, ...).
#
#   curl -fsSL https://raw.githubusercontent.com/vulrun/repo-tools/main/install.sh | bash
#   ./install.sh                  from a clone
#   ./install.sh --uninstall
#
# Works with bash 3.2 too, so it runs on a stock Mac.
set -euo pipefail

REF="${REF:-main}"
REPO="${REPO:-vulrun/repo-tools}"
DEST="${DEST:-$HOME/.local/bin}"
ARCHIVE_URL="${ARCHIVE_URL:-https://github.com/$REPO/archive/$REF.tar.gz}"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/repo-tools"
MARK="# added by the ghrepo/glrepo installer"

say() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

usage() {
cat <<EOF
Installs every tool in bin/ (ghrepo, glrepo, ...) into $DEST.

USAGE
  ./install.sh                  install or update from this folder
  curl -fsSL .../install.sh | bash
                                install or update from GitHub
  ./install.sh --uninstall      remove the installed tools
  ./install.sh --help

SETTINGS (environment variables)
  DEST    where the tools go          (now: $DEST)
  REF     branch or tag to download   (now: $REF)
  REPO    GitHub owner/repo           (now: $REPO)

Running it again updates the tools. If DEST isn't on your PATH, a line
is added to ~/.bashrc, and to ~/.zshrc if you have one.
EOF
}

uninstall() {
  local list="$STATE_DIR/installed" f
  [ -f "$list" ] || die "nothing to uninstall (no record at $list)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$f" ]; then rm -f "$f"; say "Removed $f"; fi
  done < "$list"
  rm -f "$list"
  say "Done. Any PATH line in your shell rc file was left in place."
}

case "${1:-}" in
  -h|--help)   usage; exit 0 ;;
  --uninstall) uninstall; exit 0 ;;
  "")          ;;
  *)           echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

# ---------- find the tools ----------

src_dir=""
here="${BASH_SOURCE[0]:-}"
if [ -n "$here" ] && [ -f "$here" ] && [ -d "$(dirname "$here")/bin" ]; then
  src_dir="$(cd "$(dirname "$here")" && pwd)"
  say "Installing from $src_dir"
else
  case "$ARCHIVE_URL" in
    *vulrun/repo-tools*) die "REPO isn't set. Edit REPO in install.sh, or run with REPO=owner/repo" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v tar  >/dev/null 2>&1 || die "tar is not installed"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading $REPO ($REF)"
  curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$tmp" || die "download failed: $ARCHIVE_URL"
  src_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$src_dir" ] && [ -d "$src_dir/bin" ] || die "no bin/ folder in the download"
fi

# ---------- install ----------

mkdir -p "$DEST" "$STATE_DIR"
new_list="$STATE_DIR/installed.new"
: > "$new_list"
count=0
for f in "$src_dir"/bin/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  install -m 0755 "$f" "$DEST/$name"
  echo "$DEST/$name" >> "$new_list"
  say "Installed $name"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no tools found in $src_dir/bin"

# Keep a record of everything ever installed, for --uninstall.
touch "$STATE_DIR/installed"
sort -u "$STATE_DIR/installed" "$new_list" > "$STATE_DIR/installed.tmp"
mv "$STATE_DIR/installed.tmp" "$STATE_DIR/installed"
rm -f "$new_list"

# ---------- PATH ----------

rc_changed=""
case ":$PATH:" in
  *":$DEST:"*) ;;
  *)
    case "$DEST" in
      "$HOME"/*) shown="\$HOME/${DEST#"$HOME"/}" ;;
      *)         shown="$DEST" ;;
    esac
    line="export PATH=\"$shown:\$PATH\""
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ "$rc" = "$HOME/.bashrc" ] || [ -f "$rc" ] || continue
      if ! grep -qF "$line" "$rc" 2>/dev/null; then
        printf '\n%s\n%s\n' "$MARK" "$line" >> "$rc"
        say "Added $shown to PATH in $rc"
        rc_changed="$rc_changed $rc"
      fi
    done
    ;;
esac

# ---------- dependency hints ----------

missing=""
for t in git gh glab jq; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  echo
  echo "Note: not found on this machine:$missing"
  echo "      ghrepo needs git and gh. glrepo needs git, glab and jq."
fi

bash_major="$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
if [ "$bash_major" -lt 4 ]; then
  echo
  echo "Note: the tools need bash 4 or newer; this machine has bash $bash_major."
  echo "      On macOS: brew install bash"
fi

echo
if [ -n "$rc_changed" ]; then
  say "Done. Open a new terminal (or run: source ~/.bashrc), then try: ghrepo --help"
else
  say "Done. Try: ghrepo --help"
fi
