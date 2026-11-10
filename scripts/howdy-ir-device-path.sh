#!/bin/bash
# ===========================================================================
# howdy-ir-device-path.sh — make Howdy's device_path name the IR capture node
# that actually exists on THIS boot.
#
# IPU7 ISYS capture nodes are numbered in bind order, so the HM1092's
# /dev/videoN moves between boots. Howdy's config.ini holds one literal path,
# and until now install.sh could only tell you to go and set it by hand
# (tools/find-ir-node.sh prints it; nothing kept it true).
#
# Two things go wrong with a stale path, and the second is why this runs before
# any login manager:
#
#   1. it names nothing, or an unrelated node, and face unlock simply fails;
#   2. it names a *working RGB* capture node. The HM1092 failing to bind while
#      the OV05C10 binds is a normal failure on this hardware, and then face
#      recognition runs on a VISIBLE-LIGHT camera -- which a photograph
#      defeats -- wired in as `auth sufficient pam_howdy.so` for sudo, for the
#      login manager and for the screen locker.
#
# So when the IR node cannot be resolved, this FAILS CLOSED: device_path is set
# to `none`, Howdy reports "not possible to open camera at configured path", PAM
# falls through to the password, and nothing authenticates off the RGB sensor.
# `--keep-stale` opts out of that and leaves whatever is in the file.
#
# Resolving the node is lib-detect.sh's job: it follows the hm1092 entity's own
# links through the media graph. Nothing in here knows a CSI-2 port or a node
# number, which is the whole point -- a guessed node is indistinguishable from a
# detected one once it is written to the config.
#
#   sudo ./howdy-ir-device-path.sh            # resolve and write
#   ./howdy-ir-device-path.sh --dry-run       # print the verdict, change nothing
#   sudo ./howdy-ir-device-path.sh --wait 30  # wait longer for the media graph
#
# Options:
#   --wait N       seconds to wait for the media graph to appear (default 10)
#   --keep-stale   do not fail closed; leave device_path alone if unresolved
#   --config PATH  use this config.ini instead of searching for one
#   --dry-run      print what would change, write nothing (no root needed)
#
# Exit: 0  the config names the detected IR node, or there is no Howdy here
#       1  the IR node could not be resolved (see the message; default is that
#          device_path was set to `none`, so face unlock is OFF, not guessing)
#       2  bad usage, or lib-detect.sh is missing from this install
# ===========================================================================
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SELFDIR=$(dirname "$SELF")
TAG=howdy-ir-device-path

log(){ printf '%s: %s\n' "$TAG" "$*"; }
err(){ printf '%s: %s\n' "$TAG" "$*" >&2; }

WAIT=10; KEEP_STALE=0; DRY=0; CFG_ARG=""
while [ $# -gt 0 ]; do
  case $1 in
    --wait)       [ $# -ge 2 ] || { err "--wait needs a number of seconds"; exit 2; }; WAIT=$2; shift 2 ;;
    --wait=*)     WAIT=${1#*=}; shift ;;
    --config)     [ $# -ge 2 ] || { err "--config needs a path"; exit 2; };            CFG_ARG=$2; shift 2 ;;
    --config=*)   CFG_ARG=${1#*=}; shift ;;
    --keep-stale) KEEP_STALE=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    sed -n '3,/^# ===/p' "$SELF" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *)            err "unknown option: $1 (try --help)"; exit 2 ;;
  esac
done
case $WAIT in
  ''|*[!0-9]*) err "--wait takes whole seconds, got: $WAIT"; exit 2 ;;
esac

# One implementation of "where is the camera", shared with verify.sh and
# find-ir-node.sh. Installed layout keeps it next to this script; the repo
# layout has it in tools/.
LIB=""
for c in "$SELFDIR/lib-detect.sh" "$SELFDIR/../tools/lib-detect.sh"; do
  [ -f "$c" ] && { LIB=$(readlink -f "$c"); break; }
done
if [ -z "$LIB" ]; then
  err "lib-detect.sh is not next to this script or in ../tools — this script cannot resolve anything on its own, and will not guess a node"
  exit 2
fi
# shellcheck source=/dev/null
. "$LIB"

# Howdy's config path differs by version and packaging; this is the same list
# install.sh and verify.sh search, in the same order.
CFG=""
if [ -n "$CFG_ARG" ]; then
  if [ -f "$CFG_ARG" ]; then CFG=$CFG_ARG; else err "no such config file: $CFG_ARG"; exit 2; fi
else
  for c in /etc/howdy/config.ini /usr/lib/howdy/config.ini \
           /usr/local/lib/howdy/config.ini /usr/lib/security/howdy/config.ini \
           /usr/local/lib/security/howdy/config.ini; do
    [ -f "$c" ] && { CFG=$c; break; }
  done
fi
# No Howdy is not a failure: it is the same "nothing to do here" install.sh
# reports as a skipped step. A red unit on a machine with no face unlock would
# only teach people to ignore this one.
if [ -z "$CFG" ]; then
  log "no Howdy config.ini found — nothing to point at a camera, doing nothing"
  exit 0
fi
if [ $DRY -eq 0 ] && [ ! -w "$CFG" ]; then
  err "cannot write $CFG — run as root, or use --dry-run"
  exit 2
fi

CUR=$(sed -n 's/^device_path[[:space:]]*=[[:space:]]*//p' "$CFG" | head -1)
CUR=${CUR%% *}

# Wait for the graph rather than for a fixed time: at boot this normally
# resolves on the first pass, and the full wait only elapses on a machine where
# the sensor never bound -- which is exactly when we must not keep a stale path.
DEADLINE=$(( $(date +%s) + WAIT ))
while :; do
  ld_detect >/dev/null 2>&1 || true
  [ -n "${LD_NODE:-}" ] && break
  [ "$(date +%s)" -lt "$DEADLINE" ] || break
  sleep 1
done

if [ -n "${LD_NODE:-}" ]; then
  WANT=${LD_NODE:-}
  WHY="the ${LD_IR_SENS:-hm1092} entity links to ${LD_CSI:-a CSI-2 receiver} -> ${LD_CAP:-its capture entity}"
else
  if [ $KEEP_STALE -eq 1 ]; then
    err "could not resolve the IR capture node: ${LD_WHY:-no hm1092 capture node in the media graph}"
    err "--keep-stale given, so device_path stays as '${CUR:-unset}' — if that node is the RGB camera, face unlock is running on visible light"
    exit 1
  fi
  WANT=none
  WHY="${LD_WHY:-no hm1092 capture node in the media graph}"
fi

if [ "$CUR" = "$WANT" ]; then
  if [ "$WANT" = none ]; then
    log "IR node not resolved ($WHY); device_path is already 'none' — face unlock stays off"
    exit 1
  fi
  log "device_path is already $WANT ($WHY)"
  exit 0
fi

if [ $DRY -eq 1 ]; then
  log "would set device_path = $WANT in $CFG (was '${CUR:-unset}')"
  [ "$WANT" = none ] && { log "reason: $WHY"; exit 1; }
  log "reason: $WHY"
  exit 0
fi

# No per-run backup: this runs every boot, and a directory filling with
# config.ini.bak-* is its own kind of mess. The old value is in the journal
# line below, which is what you actually need when something looks wrong.
if grep -qE '^device_path[[:space:]]*=' "$CFG"; then
  sed -i "s|^device_path[[:space:]]*=.*|device_path = $WANT|" "$CFG"
else
  err "$CFG has no device_path line to set — is this a Howdy config?"
  exit 2
fi

# sed exits 0 when it matched nothing, and on a read-only /etc it can fail
# without saying so. Read the value back out of the file before claiming it.
NEW=$(sed -n 's/^device_path[[:space:]]*=[[:space:]]*//p' "$CFG" | head -1)
NEW=${NEW%% *}
if [ "$NEW" != "$WANT" ]; then
  err "tried to set device_path = $WANT in $CFG but it still reads '${NEW:-unset}' — is /etc read-only?"
  exit 2
fi

if [ "$WANT" = none ]; then
  err "could not resolve the IR capture node: $WHY"
  err "device_path was '${CUR:-unset}'; set to 'none' so Howdy fails to open a camera instead of possibly using the RGB sensor. Face unlock is OFF until this resolves."
  exit 1
fi
log "device_path: ${CUR:-unset} -> $WANT ($WHY)"
exit 0
