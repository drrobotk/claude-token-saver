#!/usr/bin/env bash
# token-saver installer.
#   curl -fsSL https://raw.githubusercontent.com/drrobotk/claude-token-saver/main/install.sh | bash
# Installs the CLI only. It touches no Claude Code config until you run it.
set -euo pipefail

REPO="${TOKEN_SAVER_REPO:-https://github.com/drrobotk/claude-token-saver.git}"
DEST="${TOKEN_SAVER_HOME:-$HOME/.token-saver}"
BIN_DIR="${TOKEN_SAVER_BIN:-$HOME/.local/bin}"

G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; D=$'\033[2m'; N=$'\033[0m'
say() { printf '%s\n' "$*"; }

command -v git >/dev/null 2>&1     || { printf '%s\n' "${R}git is required${N}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' "${R}python3 is required${N}"; exit 1; }

if [ -d "$DEST/.git" ]; then
    say "${D}updating $DEST${N}"
    git -C "$DEST" pull --ff-only --quiet
else
    say "${D}cloning into $DEST${N}"
    git clone --depth 1 --quiet "$REPO" "$DEST"
fi

mkdir -p "$BIN_DIR"
ln -sf "$DEST/bin/token-saver" "$BIN_DIR/token-saver"
chmod +x "$DEST/bin/token-saver"

say ""
say "${G}token-saver installed${N} -> $BIN_DIR/token-saver"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "${Y}$BIN_DIR is not on your PATH. Add this to your shell profile:${N}"
       say "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

say ""
say "Next:"
say "  token-saver              ${D}# what you already have, and what conflicts${N}"
say "  token-saver conflicts    ${D}# which tools can never run together${N}"
say "  token-saver install best ${D}# install and enable the curated stack${N}"
say ""
say "${D}Nothing in ~/.claude has been changed. Every later edit is backed up to${N}"
say "${D}~/.claude/.token-saver-state and is reversible with: token-saver off${N}"
