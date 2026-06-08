#!/usr/bin/env bash
# deploy.sh — Gateduino ESPHome deployment
# Usage:
#   ./deploy.sh all          # flash all three nodes
#   ./deploy.sh front        # flash gateduino-front only
#   ./deploy.sh back         # flash gateduino-back only
#   ./deploy.sh gate         # flash gateduino-gate only
#   ./deploy.sh compile all  # compile only (no flash)

set -euo pipefail

ESPHOME_DIR="$(cd "$(dirname "$0")/esphome" && pwd)"
TARGET="${1:-all}"
ACTION="${2:-run}"  # run = compile + flash, compile = compile only

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[gateduino]${NC} $1"; }
ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
fail() { echo -e "${RED}[fail]${NC} $1"; exit 1; }

# Verify esphome is available
if ! command -v esphome &>/dev/null; then
  fail "esphome not found. Install with: pip install esphome"
fi

# Verify secrets.yaml exists
if [ ! -f "$ESPHOME_DIR/secrets.yaml" ]; then
  fail "esphome/secrets.yaml not found. Copy secrets.yaml.example and fill in your values."
fi

flash_node() {
  local node="$1"
  local yaml="$ESPHOME_DIR/gateduino-${node}.yaml"

  if [ ! -f "$yaml" ]; then
    fail "Config not found: $yaml"
  fi

  log "Processing gateduino-${node}..."

  if [ "$ACTION" = "compile" ]; then
    esphome compile "$yaml" && ok "gateduino-${node} compiled"
  else
    esphome run "$yaml" && ok "gateduino-${node} flashed"
  fi
}

case "$TARGET" in
  all)
    log "Flashing all nodes (front, back, gate)..."
    log "Flashing scanners first — gate stays closed during this phase."
    flash_node front
    flash_node back
    log "Scanners online. Now flashing gate node..."
    flash_node gate
    ok "All nodes deployed."
    ;;
  front|back|gate)
    flash_node "$TARGET"
    ;;
  compile)
    ACTION="compile"
    TARGET="${2:-all}"
    if [ "$TARGET" = "all" ]; then
      flash_node front
      flash_node back
      flash_node gate
    else
      flash_node "$TARGET"
    fi
    ;;
  *)
    echo "Usage: $0 [all|front|back|gate|compile] [all|front|back|gate]"
    echo ""
    echo "Examples:"
    echo "  $0 all          # compile and flash all nodes"
    echo "  $0 front        # compile and flash front scanner"
    echo "  $0 compile all  # compile all without flashing"
    exit 1
    ;;
esac
