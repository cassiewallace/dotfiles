#!/usr/bin/env bash
# Dotfiles installer.
#
# - Symlinks tracked files from this repo into $HOME (stow-style, no external deps).
# - Restores forked/external agent skills listed in skills.manifest.
# - Optionally runs `brew bundle` if --brew is passed and a Brewfile exists.
#
# Re-running on the same machine is a no-op.
#
# Usage:
#   ./install.sh                # symlink dotfiles + restore skills
#   ./install.sh --dry-run      # print planned actions; change nothing
#   ./install.sh --brew         # also run `brew bundle` against ./Brewfile
#   ./install.sh --skip-skills  # skip the skills.manifest restore step

set -euo pipefail

DRY_RUN=0
DO_BREW=0
SKIP_SKILLS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --brew)        DO_BREW=1 ;;
    --skip-skills) SKIP_SKILLS=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '%s\n' "$*"; }
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer targets macOS." >&2
  exit 1
fi

# --- 1. Symlink dotfile packages into $HOME -----------------------------------

# Each top-level subdir whose name does not start with `.` or `_` and which
# contains dotfile-style entries (anything beginning with a dot at depth 1) is
# treated as a "package". The package's tree mirrors $HOME exactly.
link_package() {
  local pkg="$1"
  local pkg_dir="$REPO_DIR/$pkg"
  [[ -d "$pkg_dir" ]] || return 0

  log ""
  log "Linking package: $pkg"

  # Find every regular file inside the package and link its $HOME counterpart.
  # Using files (not dirs) keeps existing unrelated content in $HOME directories
  # like ~/.claude untouched.
  while IFS= read -r -d '' src; do
    local rel="${src#"$pkg_dir"/}"
    local dest="$HOME/$rel"
    local dest_dir
    dest_dir="$(dirname "$dest")"

    run "mkdir -p \"$dest_dir\""

    if [[ -L "$dest" ]]; then
      local current
      current="$(readlink "$dest")"
      if [[ "$current" == "$src" ]]; then
        log "  ok   $rel"
        continue
      fi
      log "  relink $rel (was -> $current)"
      run "ln -sfn \"$src\" \"$dest\""
    elif [[ -e "$dest" ]]; then
      local backup="${dest}.dotfiles-backup-${TIMESTAMP}"
      log "  backup $rel -> $(basename "$backup")"
      run "mv \"$dest\" \"$backup\""
      run "ln -s \"$src\" \"$dest\""
    else
      log "  link $rel"
      run "ln -s \"$src\" \"$dest\""
    fi
  done < <(find "$pkg_dir" -type f -print0)
}

for pkg in zsh claude; do
  link_package "$pkg"
done

# --- 2. Restore forked/external agent skills ----------------------------------

if [[ "$SKIP_SKILLS" -eq 1 ]]; then
  log ""
  log "Skipping skills restore (--skip-skills)."
elif [[ -f "$REPO_DIR/skills.manifest" ]]; then
  log ""
  log "Restoring skills from skills.manifest"

  if ! command -v npx >/dev/null 2>&1; then
    log "  npx not found on PATH: install Node (brew install node) before running skill restore."
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      # strip comments + leading/trailing whitespace
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue

      local_name="${line%%|*}"
      cmd="${line#*|}"
      local_name="${local_name%"${local_name##*[![:space:]]}"}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"

      if [[ "$cmd" == manual:* ]]; then
        log "  skip $local_name (manual install: ${cmd#manual:})"
        continue
      fi

      if [[ -d "$HOME/.agents/skills/$local_name" ]]; then
        log "  ok   $local_name (already installed)"
        continue
      fi

      log "  install $local_name"
      run "$cmd"
    done < "$REPO_DIR/skills.manifest"
  fi
else
  log ""
  log "No skills.manifest found: skipping skill restore."
fi

# --- 3. Optional Homebrew bootstrap -------------------------------------------

if [[ "$DO_BREW" -eq 1 ]]; then
  log ""
  if [[ ! -f "$REPO_DIR/Brewfile" ]]; then
    log "No Brewfile found: skipping brew bundle."
  elif ! command -v brew >/dev/null 2>&1; then
    log "brew not found on PATH: install Homebrew first (https://brew.sh)."
  else
    log "Running brew bundle"
    run "brew bundle --file=\"$REPO_DIR/Brewfile\""
  fi
fi

log ""
log "Done."
