#!/usr/bin/env bash
set -euo pipefail

# Do not run as sudo, unless you change how COMMANDER is defined
if [ "$EUID" -eq 0 ]; then
  log "Do not run this script as root."
  exit 1
fi

# Ensure the script always uses the current directory for firmware files
CURRENT_DIR=$(pwd)

# Simple logging helper: prints to screen and syslog
# Uses only POSIX features to avoid shell-specific breakage
LOG_TAG=${LOG_TAG:-secureboot}
# Unified logger: print to screen and write to syslog
log() {
  if [ $# -gt 0 ]; then
    printf "%s\n" "$*"
    logger -t "$LOG_TAG" -- "$*"
  else
    printf "\n"
    # Intentionally do not write empty lines to syslog
  fi
}

# CSV field sanitizer: remove CR/LF and escape double quotes
csv_escape() {
  local s="${1:-}"
  s=${s//$'\r'/}
  s=${s//$'\n'/}
  s=${s//\"/\"\"}
  printf "%s" "$s"
}

# Firmware binaries root (override with BIN_DIR_NAME env)
BIN_DIR_NAME=${BIN_DIR_NAME:-binaries}
BIN_ROOT="$(pwd)/$BIN_DIR_NAME"
# VERSION will be selected interactively from BIN_ROOT
# This is the update version that is meant to be OTA'd to the device to make sure it can take an upgrade
# - Of course if you do an OTA test, flash it back to what it was before the test
UPDATE_VERSION="0.0.14"

# Based on Ubuntu Linux installation of Simplicity Studio 5; adjust if your commander is elsewhere or named differently
COMMANDER="$HOME/Downloads/SimplicityStudio_v5/developer/adapter_packs/commander/commander"

log "This is the commander path: $COMMANDER"

# Verify commander exists and is executable
if [ ! -x "$COMMANDER" ]; then
  log "ERROR: Commander not found or not executable at: $COMMANDER"
  log "Please install Simplicity Commander or update the path, then re-run."
  exit 1
fi

# Discover available programmers and require explicit selection
log "Detecting connected programmers..."
PROGRAMMER_OUTPUT=$($COMMANDER -v 2>&1)
mapfile -t AVAILABLE_SERIALS < <(echo "$PROGRAMMER_OUTPUT" | grep -o 'SN=[0-9]*' | cut -d= -f2)

if [ ${#AVAILABLE_SERIALS[@]} -eq 0 ]; then
  log "ERROR: No programmers detected"
  log "Please connect a programmer and try again"
  exit 1
elif [ ${#AVAILABLE_SERIALS[@]} -eq 1 ]; then
  SERIAL="${AVAILABLE_SERIALS[0]}"
  log "Found 1 programmer: $SERIAL"
else
  log "Found ${#AVAILABLE_SERIALS[@]} programmers:"
  for i in "${!AVAILABLE_SERIALS[@]}"; do
    idx=$((i+1))
    printf "  %d) %s\n" "$idx" "${AVAILABLE_SERIALS[$i]}"
  done

  SERIAL=""
  while [ -z "$SERIAL" ]; do
    printf "Select programmer by number [1-${#AVAILABLE_SERIALS[@]}]: "
    read -r PROG_CHOICE
    if [[ "$PROG_CHOICE" =~ ^[0-9]+$ ]]; then
      if [ "$PROG_CHOICE" -ge 1 ] && [ "$PROG_CHOICE" -le ${#AVAILABLE_SERIALS[@]} ]; then
        SERIAL="${AVAILABLE_SERIALS[$((PROG_CHOICE-1))]}"
      else
        log "Invalid number. Enter 1..${#AVAILABLE_SERIALS[@]}"
      fi
    else
      log "Invalid input. Please enter a number."
    fi
  done
  log "Selected programmer: $SERIAL"
fi

# Ensure adapter is in MINI mode for programmer board
ensure_adapter_mini() {
  local mode_out current_mode
  mode_out="$($COMMANDER adapter dbgmode --serialno "$SERIAL" 2>&1 || true)"
  current_mode=$(echo "$mode_out" | awk -F': ' '/^Debug Mode:/ {print $2}' | tr -d ' \r')
  if [ "$current_mode" = "MCU" ]; then
    log "Adapter dbgmode: MCU (OK)"
    return 0
  fi
  log "Adapter dbgmode was $current_mode; setting to MCU..."
  if $COMMANDER adapter dbgmode MCU --serialno "$SERIAL" >/dev/null 2>&1; then
    mode_out="$($COMMANDER adapter dbgmode --serialno "$SERIAL" 2>&1 || true)"
    current_mode=$(echo "$mode_out" | awk -F': ' '/^Debug Mode:/ {print $2}' | tr -d ' \r')
    if [ "$current_mode" = "MCU" ]; then
      log "Adapter dbgmode set to MCU (was $current_mode): OK"
      return 0
    fi
  fi
  OVERALL_STATUS=ERROR
  ERROR_REASON="Setting adapter dbgmode MCU failed (current: ${current_mode:-unknown})"
  ERROR_LINE=$LINENO
  log "ERROR: Failed to set adapter dbgmode MCU. Exiting."
  exit 1
}

# -------------------------
# Service menu (-m)
# -------------------------
# Intentionally avoids using the 'log' helper to prevent syslog writes.
service_menu() {
  echo ""
  echo "==============================================="
  echo "         SERVICE MENU - HANDLE WITH CARE      "
  echo "==============================================="
  echo ""
  echo "  1) Unlock debug + Mass erase"
  echo "  2) Flash without lock (debugging mode)"
  echo "  q) Quit"
  echo ""
  echo "==============================================="
  echo ""
  printf "Select an option: "
  read -r choice
  echo ""
  case "${choice:-}" in
    1)
      echo "Unlocking debug..."
      ensure_adapter_mini
      if "$COMMANDER" device lock --debug disable --serialno "$SERIAL" --device EFR32ZG23B020F512IM48; then
        echo "Debug unlocked. Proceeding to mass erase..."
        if "$COMMANDER" device masserase --serialno "$SERIAL" --device EFR32ZG23B020F512IM48; then
          echo "Mass erase complete."
          exit 0
        else
          echo "Mass erase failed."
          exit 1
        fi
      else
        echo "Failed to unlock debug."
        exit 1
      fi
      ;;
    2)
      echo "Flash without lock mode enabled."
      echo "Device will remain unlocked for debugging after flashing."
      SKIP_LOCK=1
      export SKIP_LOCK
      return
      ;;
    q|Q|"")
      echo "Exiting..."
      exit 0 ;;
    *)
      echo "Unknown selection."
      exit 1 ;;
  esac
}

# Early arg gate for service menu; exits before any logging/traps.
if [ "${1:-}" = "-m" ] || [ "${1:-}" = "--menu" ]; then
  service_menu
fi

# Banner with aligned borders (color optional)
if [ -t 1 ]; then
  COLOR_BORDER=$'\033[36m'   # cyan
  COLOR_RESET=$'\033[0m'
else
  COLOR_BORDER=""
  COLOR_RESET=""
fi

BANNER_WIDTH=75
CONTENT_WIDTH=$((BANNER_WIDTH - 3))
print_border() {
  printf "%s" "$COLOR_BORDER"
  printf "%*s" "$BANNER_WIDTH" "" | tr ' ' '#'
  printf "%s\n" "$COLOR_RESET"
}
print_line() {
  local line="$1"
  printf "%s#%s " "$COLOR_BORDER" "$COLOR_RESET"
  printf "%-*s" "$CONTENT_WIDTH" "$line"
  printf "%s#%s\n" "$COLOR_BORDER" "$COLOR_RESET"
}

print_border
print_line "Secure Boot Flasher"
print_line "Flow: unlock > mass erase > keys > flash > QR > lock > update test GBL"
print_border
  
# Board tracking setup
if [ -z "${BOARD_ID:-}" ]; then
  printf "\nInstructions:\n"
  printf " - Enter a unique device ID (Board ID).\n"
  printf " - If this ID was used before, you'll be warned.\n"
  printf " - You can rename or accept an automatic '-N' suffix.\n"
  printf " - The ID appears in logs and labels for traceability.\n\n"
  printf "What this program does:\n"
  printf " - Checks for duplicate Board ID and offers renaming.\n"
  printf " - Unlocks debug and performs a mass erase.\n"
  printf " - Flashes security keys (AES + signing tokens).\n"
  printf " - Dumps tokens (pre) to verify access.\n"
  printf " - Flashes firmware images for the device.\n"
  printf " - Reads Z-Wave QR and derives the DSK.\n"
  printf " - Locks debug and confirms tokens are blocked (post).\n"
  printf " - Creates a signed/encrypted GBL update file.\n"
  printf " - Saves a QR PNG and writes CSV/text logs.\n\n"
  printf "Enter board number: "
  read -r BOARD_ID
fi

# Require Board ID to be numeric
while ! [[ "${BOARD_ID}" =~ ^[0-9]+$ ]]; do
  log "Board ID must be numeric."
  # printf to avoid newline
  printf "Enter numeric board number: "
  read -r BOARD_ID
done
# Duplicate check using CSV log (counts prior instances of this Board ID)
INSTANCE_NUM=1
BOARD_LABEL="$BOARD_ID"
LOG_CSV_PATH="$(pwd)/flash_logs/flash_log.csv"
if [ -f "$LOG_CSV_PATH" ]; then
  DUP_INFO=$(awk -F',' -v id="$BOARD_ID" '
    NR>1 {
      b=$4; gsub(/^"|"$/, "", b); gsub(/\r$/, "", b);
      n=split(b, parts, "-");
      if (parts[1] == id) {
        count++;
        inst = (n>1 && parts[2] ~ /^[0-9]+$/) ? parts[2]+0 : 1;
        if (inst > max) max = inst;
      }
    }
    END { printf "%d %d", count+0, max+0 }
  ' "$LOG_CSV_PATH" 2>/dev/null || echo "0 0")
  DUP_COUNT=$(echo "$DUP_INFO" | awk '{print $1}')
  MAX_INST=$(echo "$DUP_INFO" | awk '{print $2}')
else
  DUP_COUNT=0
  MAX_INST=0
fi

# Handle duplicate Board IDs:
# - If duplicate found, warn user and offer options:
#   1. Enter a new ID (will be re-checked for duplicates)
#   2. Accept auto-generated suffix: original-N (where N = highest instance + 1)
# - Examples: "123" exists → suggest "123-1"; "123-1" exists → suggest "123-2"
# - This prevents overwriting historical logs and maintains unique board tracking
if [ "$DUP_COUNT" -gt 0 ]; then
  INSTANCE_NUM=$((MAX_INST + 1))
  log "WARNING: Board ID '$BOARD_ID' already logged $DUP_COUNT time(s)."
  printf "Enter a new device ID, or press Enter to use '%s-%d': " "$BOARD_ID" "$INSTANCE_NUM"
  read -r NEW_NAME
  if [ -n "$NEW_NAME" ]; then
    while ! [[ "$NEW_NAME" =~ ^[0-9]+$ ]]; do
      log "Board ID must be numeric."
      # printf to avoid newline
      printf "Enter numeric board number: "
      read -r NEW_NAME
    done
    BOARD_ID="$NEW_NAME"
    # Recompute counts for the new ID
    DUP_INFO=$(awk -F',' -v id="$BOARD_ID" '
      NR>1 {
        b=$4; gsub(/^"|"$/, "", b); gsub(/\r$/, "", b);
        n=split(b, parts, "-");
        if (parts[1] == id) {
          count++;
          inst = (n>1 && parts[2] ~ /^[0-9]+$/) ? parts[2]+0 : 1;
          if (inst > max) max = inst;
        }
      }
      END { printf "%d %d", count+0, max+0 }
    ' "$LOG_CSV_PATH" 2>/dev/null || echo "0 0")
    DUP_COUNT=$(echo "$DUP_INFO" | awk '{print $1}')
    MAX_INST=$(echo "$DUP_INFO" | awk '{print $2}')
    if [ "$DUP_COUNT" -gt 0 ]; then
      INSTANCE_NUM=$((MAX_INST + 1))
      BOARD_LABEL="$BOARD_ID-$INSTANCE_NUM"
    else
      INSTANCE_NUM=1
      BOARD_LABEL="$BOARD_ID"
    fi
  else
    BOARD_LABEL="$BOARD_ID-$INSTANCE_NUM"
  fi
else
  INSTANCE_NUM=1
  BOARD_LABEL="$BOARD_ID"
fi

# Optional note about this board
printf "Enter an optional note about this board (press Enter to skip): "
read -r BOARD_NOTE
TIMESTAMP=$(date -Iseconds)
HOST=$(hostname)
USER_NAME=$(whoami)
OVERALL_STATUS=COMPLETE
STATUS_UNLOCK=ERROR
STATUS_MASSERASE=ERROR
STATUS_FLASH_KEYS=ERROR
STATUS_TOKENDUMP_PRE=ERROR
STATUS_FLASH_FW=ERROR
STATUS_QR_READ=ERROR
STATUS_LOCKDEBUG=ERROR
STATUS_TOKENDUMP_POST=ERROR

# Error tracking and early-exit logging
ERROR_REASON=""
ERROR_LINE=0
LOGS_WRITTEN=0

on_exit() {
  if [ "${OVERALL_STATUS:-}" = "ERROR" ] && [ "${LOGS_WRITTEN:-0}" -eq 0 ]; then
    mkdir -p "$(pwd)/flash_logs"
    LOG_CSV="$(pwd)/flash_logs/flash_log.csv"
    CSV_HEADER="Date,Host,User,Board,Flasher Serial,Version,Variant,Update Version,QR Code,DSK,Note,Result,Unlock,Mass Erase,Flash Keys,Token Dump (pre),Flash Firmware,QR Read,Lock Debug,Token Dump (post)"
    if [ ! -f "$LOG_CSV" ]; then
      printf "%s\n" "$CSV_HEADER" >> "$LOG_CSV"
    fi
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
      "$(csv_escape "${TIMESTAMP:-}")" \
      "$(csv_escape "${HOST:-}")" \
      "$(csv_escape "${USER_NAME:-}")" \
      "$(csv_escape "${BOARD_LABEL:-}")" \
      "$(csv_escape "${SERIAL:-}")" \
      "$(csv_escape "${VERSION:-}")" \
      "$(csv_escape "${VARIANT_SUFFIX:-}")" \
      "$(csv_escape "${UPDATE_VERSION:-}")" \
      "$(csv_escape "${QR_NUM:-}")" \
      "$(csv_escape "${FORMATTED_SERIAL:-}")" \
      "$(csv_escape "${BOARD_NOTE:-(none entered)}")" \
      "$(csv_escape "${OVERALL_STATUS:-ERROR}")" \
      "$(csv_escape "${STATUS_UNLOCK:-ERROR}")" \
      "$(csv_escape "${STATUS_MASSERASE:-ERROR}")" \
      "$(csv_escape "${STATUS_FLASH_KEYS:-ERROR}")" \
      "$(csv_escape "${STATUS_TOKENDUMP_PRE:-ERROR}")" \
      "$(csv_escape "${STATUS_FLASH_FW:-ERROR}")" \
      "$(csv_escape "${STATUS_QR_READ:-ERROR}")" \
      "$(csv_escape "${STATUS_LOCKDEBUG:-ERROR}")" \
      "$(csv_escape "${STATUS_TOKENDUMP_POST:-ERROR}")" >> "$LOG_CSV"
    LOG_TXT="$(pwd)/flash_logs/flash_log.txt"
    {
      printf "\n----------------------------------------\n"
      printf "Date:        %s\n" "${TIMESTAMP:-}"
      printf "Host/User:   %s / %s\n" "${HOST:-}" "${USER_NAME:-}"
      printf "Board:       %s\n" "${BOARD_LABEL:-}"
      printf "Note:        %s\n" "${BOARD_NOTE:-"(none entered)"}"
      printf "Flasher Serial: %s\n" "${SERIAL:-}"
      printf "Version:     %s  (Update: %s)\n" "${VERSION:-}" "${UPDATE_VERSION:-}"
      printf "Variant:     %s\n" "${VARIANT_SUFFIX:-}"
      printf "Result:      %s\n" "${OVERALL_STATUS:-ERROR}"
      if [ -n "${ERROR_REASON}" ]; then
        printf "Error:       %s (line %s)\n" "${ERROR_REASON}" "${ERROR_LINE}" 
      fi
      printf "QR Code:     %s\n" "${QR_NUM:-}"
      printf "DSK:         %s\n" "${FORMATTED_SERIAL:-}"
      printf "Steps:\n"
      printf "  - Unlock:            %s\n" "${STATUS_UNLOCK:-ERROR}"
      printf "  - Mass erase:        %s\n" "${STATUS_MASSERASE:-ERROR}"
      printf "  - Flash keys:        %s\n" "${STATUS_FLASH_KEYS:-ERROR}"
      printf "  - Tokendump (pre):   %s\n" "${STATUS_TOKENDUMP_PRE:-ERROR}"
      printf "  - Flash firmware:    %s\n" "${STATUS_FLASH_FW:-ERROR}"
      printf "  - QR read:           %s\n" "${STATUS_QR_READ:-ERROR}"
      printf "  - Lock debug:        %s\n" "${STATUS_LOCKDEBUG:-ERROR}"
      printf "  - Tokendump (post):  %s\n" "${STATUS_TOKENDUMP_POST:-ERROR}"
    } >> "$LOG_TXT"
    LOGS_WRITTEN=1
  fi
}
trap on_exit EXIT

# Discover available firmware versions and require explicit selection
if [ ! -d "$BIN_ROOT" ]; then
  log "ERROR: Binaries root not found: $BIN_ROOT"
  log "Create it and add version folders (e.g., '0.0.12')."
  if command -v xdg-open >/dev/null 2>&1; then
    log "Opening workspace folder for setup: $(pwd)"
    xdg-open "$(pwd)" >/dev/null 2>&1 || log "Could not open folder via xdg-open."
  else
    log "Open the folder manually: $(pwd)"
  fi
  exit 1
fi

mapfile -t AVAILABLE_VERSIONS < <(find "$BIN_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -Vr)
if [ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]; then
  log "ERROR: No version folders found under $BIN_ROOT"
  log "Expected structure: $BIN_ROOT/0.0.12/<variant>/..."
  if command -v xdg-open >/dev/null 2>&1; then
    log "Opening binaries root for review: $BIN_ROOT"
    xdg-open "$BIN_ROOT" >/dev/null 2>&1 || log "Could not open folder via xdg-open."
  else
    log "Open the folder manually: $BIN_ROOT"
  fi
  exit 1
fi

printf "\nAvailable firmware versions in %s (latest first):\n" "$BIN_ROOT"
for i in "${!AVAILABLE_VERSIONS[@]}"; do
  idx=$((i+1))
  printf "  %2d) %s\n" "$idx" "${AVAILABLE_VERSIONS[$i]}"
done
SUGGESTED=${AVAILABLE_VERSIONS[0]}
printf "Suggested latest: %s\n" "$SUGGESTED"
VERSION=""
while [ -z "$VERSION" ]; do
  printf "Select version by number [1=latest, Enter=latest]: "
  read -r CHOICE
  if [ -z "$CHOICE" ]; then
    VERSION="$SUGGESTED"
  elif [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#AVAILABLE_VERSIONS[@]} ]; then
      VERSION="${AVAILABLE_VERSIONS[$((CHOICE-1))]}"
    else
      log "Invalid number. Enter 1..${#AVAILABLE_VERSIONS[@]}"
    fi
  else
    log "Invalid input. Please enter a number or press Enter for latest."
  fi
done
log "Selected version: $VERSION"

# Require explicit firmware variant selection (no default)
printf "\nSelect firmware variant (size):\n"
printf "  A) test\n"
printf "  B) staging\n"
printf "  C) prod\n"
VARIANT_SUFFIX=""
while [ -z "$VARIANT_SUFFIX" ]; do
  printf "Choose variant [A/B/C]: "
  read -r VARIANT_CHOICE
  case "${VARIANT_CHOICE:-}" in
    A|a) VARIANT_SUFFIX="test" ;;
    B|b) VARIANT_SUFFIX="staging" ;;
    C|c) VARIANT_SUFFIX="prod" ;;
    *) log "Invalid choice. Please type A, B, or C." ;;
  esac
done

# Compute variant-specific directories and validate (binaries root/version/variant)
FW_BASE_DIR="$BIN_ROOT/${VERSION}/${VARIANT_SUFFIX}"
FW_UPDATE_DIR="${FW_BASE_DIR}/nextversiontest"
log "Selected variant: ${VARIANT_SUFFIX}"
log "Expected files:"
log " - Base: $BIN_ROOT/$VERSION/secureboot.s37"
log " - Update (secureboot): $FW_UPDATE_DIR/secureboot.s37"
log " - Variant: $FW_BASE_DIR/brd-xg23-20dbm.s37"
log " - Update: $FW_UPDATE_DIR/brd-xg23-20dbm.s37"

if [ ! -d "$FW_BASE_DIR" ]; then
  log "ERROR: Firmware directory not found: $FW_BASE_DIR"
  log "Tip: Ensure folder structure is '$BIN_ROOT/$VERSION/staging', '$BIN_ROOT/$VERSION/test', '$BIN_ROOT/$VERSION/prod'"
  AVAILABLE=$(ls -1d "$BIN_ROOT/${VERSION}/"* 2>/dev/null || true)
  if [ -n "$AVAILABLE" ]; then
    log "Available variant directories:\n$AVAILABLE"
  fi
  OPEN_TARGET="$BIN_ROOT/${VERSION}"
  if [ ! -d "$OPEN_TARGET" ]; then
    OPEN_TARGET="$BIN_ROOT"
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    log "Opening folder for review: $OPEN_TARGET"
    xdg-open "$OPEN_TARGET" >/dev/null 2>&1 || log "Could not open folder via xdg-open."
  else
    log "Open the folder manually: $OPEN_TARGET"
  fi
  exit 1
fi

# Change these names to match your actual firmware file names if different; the script relies on these exact names to find the files to flash and update
REQUIRED_FILES=(
  "$BIN_ROOT/$VERSION/secureboot.s37"
  "$FW_UPDATE_DIR/secureboot.s37"
  "$FW_BASE_DIR/brd-xg23-20dbm.s37"
  "$FW_UPDATE_DIR/brd-xg23-20dbm.s37"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    log "ERROR: Required file missing: $f"
    ERROR_REASON="Required file missing: $f"
    ERROR_LINE=$LINENO
    DIR_TO_OPEN=$(dirname "$f")
    if command -v xdg-open >/dev/null 2>&1; then
      log "Opening folder to inspect: $DIR_TO_OPEN"
      xdg-open "$DIR_TO_OPEN" >/dev/null 2>&1 || log "Could not open folder via xdg-open."
    else
      log "Open the folder manually: $DIR_TO_OPEN"
    fi
    exit 1
  fi
done

# Key files expected in base directory
KEY_FILES=(
  "$CURRENT_DIR/aes_key.txt"
  "$CURRENT_DIR/sign_key.pem"
  "$CURRENT_DIR/sign_key_tokens.txt"
  "$CURRENT_DIR/sign_pubkey.pem"
)

MISSING_KEYS=()
for key_file in "${KEY_FILES[@]}"; do
  if [ ! -f "$key_file" ]; then
    MISSING_KEYS+=("$key_file")
  fi
done

if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
  log "ERROR: Missing required key files in base directory:"
  for missing in "${MISSING_KEYS[@]}"; do
    log " - $missing"
  done
  printf "Generate temporary keys now? This will delete any existing key files in %s [y/N]: " "$CURRENT_DIR"
  read -r GEN_TEMP_KEYS
  if [[ "${GEN_TEMP_KEYS:-}" =~ ^[Yy]$ ]]; then
    log "Deleting existing key files and generating temporary keys..."
    rm -f "${KEY_FILES[@]}"
    if $COMMANDER util genkey --type ecc-p256 --privkey "$CURRENT_DIR/sign_key.pem" --pubkey "$CURRENT_DIR/sign_pubkey.pem" --tokenfile "$CURRENT_DIR/sign_key_tokens.txt"; then
      :
    else
      OVERALL_STATUS=ERROR
      log "Temporary signing key generation failed. Exiting."
      ERROR_REASON="Temporary signing key generation failed"
      ERROR_LINE=$LINENO
      exit 1
    fi
    if $COMMANDER util genkey --type aes-ccm --outfile "$CURRENT_DIR/aes_key.txt"; then
      log "Temporary key generation complete."
    else
      OVERALL_STATUS=ERROR
      log "Temporary AES key generation failed. Exiting."
      ERROR_REASON="Temporary AES key generation failed"
      ERROR_LINE=$LINENO
      exit 1
    fi
  else
    OVERALL_STATUS=ERROR
    log "Missing keys were not generated. Exiting."
    ERROR_REASON="Missing key files"
    ERROR_LINE=$LINENO
    exit 1
  fi
else
  log "using existing tokens"
fi

# This will unlock the port and result in a mass erase
log "unlocking debug..."
ensure_adapter_mini
if $COMMANDER device lock --debug disable --serialno "$SERIAL" --device EFR32ZG23B020F512IM48; then
  STATUS_UNLOCK=OK
else
  OVERALL_STATUS=ERROR
  log "Unlocking debug failed. Exiting."
  ERROR_REASON="Unlocking debug failed"
  ERROR_LINE=$LINENO
  exit 1
fi

# Running both mass erase and unlock just to be sure..
log "mass erasing..."
if $COMMANDER device masserase --serialno "$SERIAL" --device EFR32ZG23B020F512IM48; then
  STATUS_MASSERASE=OK
else
  OVERALL_STATUS=ERROR
  log "Mass erase failed. Exiting."
  ERROR_REASON="Mass erase failed"
  ERROR_LINE=$LINENO
  exit 1
fi

log "flashing keys..."
if $COMMANDER flash --tokengroup znet --tokenfile "$(pwd)/aes_key.txt" --tokenfile "$(pwd)/sign_key_tokens.txt" --device EFR32ZG23B020F512IM48 --serialno "$SERIAL"; then
  STATUS_FLASH_KEYS=OK
else
  OVERALL_STATUS=ERROR
  log "Flashing keys failed. Exiting."
  ERROR_REASON="Flashing keys failed"
  ERROR_LINE=$LINENO
  exit 1
fi

log "dumping tokens..."
if $COMMANDER tokendump --tokengroup znet --device EFR32ZG23B020F512IM48 --serialno "$SERIAL" >/dev/null 2>&1; then
  log "Token dump: OK (output hidden)"
  STATUS_TOKENDUMP_PRE=OK
else
  log "Token dump: ERROR"
  OVERALL_STATUS=ERROR
  ERROR_REASON="Token dump (pre) failed"
  ERROR_LINE=$LINENO
  exit 1
fi

log "flashing firmware..."
if $COMMANDER flash --device EFR32ZG23B020F512IM48 --serialno "$SERIAL" "$BIN_ROOT/$VERSION/secureboot.s37" "$FW_BASE_DIR/brd-xg23-20dbm.s37" 2>&1 \
  | awk '/^Programming range/ {printf "."; fflush(stdout)} END {print "\nDONE"}'; then
  log "Flashing firmware: COMPLETE"
  STATUS_FLASH_FW=OK
else
  log "Flashing firmware: ERROR"
  STATUS_FLASH_FW=ERROR
  OVERALL_STATUS=ERROR
  ERROR_REASON="Flashing firmware failed"
  ERROR_LINE=$LINENO
  exit 1
fi

QR_OUTPUT=$(
  $COMMANDER device zwave-qrcode \
    --serialno "$SERIAL" \
    --device EFR32ZG23B020F512IM48 \
    --timeout 5000
)

QR_NUM=$(echo "$QR_OUTPUT" | grep -o '[0-9]\{60,\}' | head -n 1)
if [ -n "$QR_NUM" ]; then
  STATUS_QR_READ=OK
else
  OVERALL_STATUS=ERROR
  log "QR read failed or code not found. Exiting."
  ERROR_REASON="QR read failed or code not found"
  ERROR_LINE=$LINENO
  exit 1
fi

FORMATTED_SERIAL=$(
  echo "$QR_NUM" \
    | cut -c13-52 \
    | sed 's/\(.....\)/\1-/g; s/-$//'
)

cat <<EOF
+----------------------------------------------------------+
|                    Z-WAVE QR & DSK                       |
+----------------------------------------------------------+
| QR CODE                                                  |
+----------------------------------------------------------+
$QR_NUM
+----------------------------------------------------------+
| DSK                                                      |
+----------------------------------------------------------+
$FORMATTED_SERIAL
+----------------------------------------------------------+
EOF

# Save QR code image (PNG) named by DSK (local package)
mkdir -p "$(pwd)/flash_logs"
QR_IMG="$(pwd)/flash_logs/${FORMATTED_SERIAL}.png"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -l M -s 8 -m 2 -o "$QR_IMG" "$QR_NUM"
  log "Saved QR code image: $QR_IMG"
else
  log "QR image not created: install 'qrencode' for PNG (e.g., sudo apt install qrencode)"
fi

if [ "${SKIP_LOCK:-0}" = "1" ]; then
  log "Skipping debug lock (service mode)"
  STATUS_LOCKDEBUG=SKIPPED
else
  logger -t "$LOG_TAG" "locking debug..."
  if $COMMANDER device lock --debug enable --serialno "$SERIAL" --device EFR32ZG23B020F512IM48; then
    STATUS_LOCKDEBUG=OK
  else
    OVERALL_STATUS=ERROR
    log "Locking debug failed. Exiting."
    ERROR_REASON="Locking debug failed"
    ERROR_LINE=$LINENO
    exit 1
  fi
fi

logger -t "$LOG_TAG" "dumping tokens after lock... expected blocked"
if POSTLOCK_TOKENDUMP_OUTPUT="$($COMMANDER tokendump --tokengroup znet --device EFR32ZG23B020F512IM48 --serialno "$SERIAL" 2>&1)"; then
  log "Post-lock token access: ACCESSIBLE (FAILED/unexpected!!!)"
  printf "%s\n" "$POSTLOCK_TOKENDUMP_OUTPUT"
  STATUS_TOKENDUMP_POST=ERROR
  OVERALL_STATUS=ERROR
  ERROR_REASON="Post-lock token access accessible (expected blocked)"
  ERROR_LINE=$LINENO
else
  log "Post-lock token access: BLOCKED (expected)"
  STATUS_TOKENDUMP_POST=OK
fi

if $COMMANDER gbl create "$FW_UPDATE_DIR/update_$UPDATE_VERSION.gbl" --app "$FW_UPDATE_DIR/brd-xg23-20dbm.s37" --sign "$(pwd)/sign_key.pem" --encrypt "$(pwd)/aes_key.txt" --compress lzma --device EFR32ZG23B020F512IM48; then
  :
else
  OVERALL_STATUS=ERROR
  log "GBL creation failed. Exiting."
  ERROR_REASON="GBL creation failed"
  ERROR_LINE=$LINENO
  exit 1
fi

# Persist run record (CSV)
mkdir -p "$(pwd)/flash_logs"
LOG_CSV="$(pwd)/flash_logs/flash_log.csv"
CSV_HEADER="Date,Host,User,Board,Flasher Serial,Version,Variant,Update Version,QR Code,DSK,Note,Result,Unlock,Mass Erase,Flash Keys,Token Dump (pre),Flash Firmware,QR Read,Lock Debug,Token Dump (post)"
if [ ! -f "$LOG_CSV" ]; then
  printf "%s\n" "$CSV_HEADER" >> "$LOG_CSV"
fi
# Write CSV row with all fields quoted and sanitized
printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
  "$(csv_escape "$TIMESTAMP")" \
  "$(csv_escape "$HOST")" \
  "$(csv_escape "$USER_NAME")" \
  "$(csv_escape "$BOARD_LABEL")" \
  "$(csv_escape "$SERIAL")" \
  "$(csv_escape "$VERSION")" \
  "$(csv_escape "${VARIANT_SUFFIX:-}")" \
  "$(csv_escape "$UPDATE_VERSION")" \
  "$(csv_escape "$QR_NUM")" \
  "$(csv_escape "$FORMATTED_SERIAL")" \
  "$(csv_escape "${BOARD_NOTE:-(none entered)}")" \
  "$(csv_escape "$OVERALL_STATUS")" \
  "$(csv_escape "$STATUS_UNLOCK")" \
  "$(csv_escape "$STATUS_MASSERASE")" \
  "$(csv_escape "$STATUS_FLASH_KEYS")" \
  "$(csv_escape "$STATUS_TOKENDUMP_PRE")" \
  "$(csv_escape "$STATUS_FLASH_FW")" \
  "$(csv_escape "$STATUS_QR_READ")" \
  "$(csv_escape "$STATUS_LOCKDEBUG")" \
  "$(csv_escape "$STATUS_TOKENDUMP_POST")" >> "$LOG_CSV"
log "Recorded flash to: $LOG_CSV"

# Human-readable summary log
LOG_TXT="$(pwd)/flash_logs/flash_log.txt"
{
  printf "\n----------------------------------------\n"
  printf "Date:        %s\n" "$TIMESTAMP"
  printf "Host/User:   %s / %s\n" "$HOST" "$USER_NAME"
  printf "Board:       %s\n" "$BOARD_LABEL"
  printf "Note:        %s\n" "${BOARD_NOTE:-"(none entered)"}"
  printf "Flasher Serial: %s\n" "$SERIAL"
  printf "Version:     %s  (Update: %s)\n" "$VERSION" "$UPDATE_VERSION"
  printf "Variant:     %s\n" "$VARIANT_SUFFIX"
  printf "Result:      %s\n" "$OVERALL_STATUS"
  printf "QR Code:     %s\n" "$QR_NUM"
  printf "DSK:         %s\n" "$FORMATTED_SERIAL"
  printf "Steps:\n"
  printf "  - Unlock:            %s\n" "$STATUS_UNLOCK"
  printf "  - Mass erase:        %s\n" "$STATUS_MASSERASE"
  printf "  - Flash keys:        %s\n" "$STATUS_FLASH_KEYS"
  printf "  - Tokendump (pre):   %s\n" "$STATUS_TOKENDUMP_PRE"
  printf "  - Flash firmware:    %s\n" "$STATUS_FLASH_FW"
  printf "  - QR read:           %s\n" "$STATUS_QR_READ"
  printf "  - Lock debug:        %s\n" "$STATUS_LOCKDEBUG"
  printf "  - Tokendump (post):  %s\n" "$STATUS_TOKENDUMP_POST"
} >> "$LOG_TXT"
log "Recorded human-readable log to: $LOG_TXT"
LOGS_WRITTEN=1

# Open logs folder in file browser (non-fatal if unavailable)
OPEN_DIR="$(pwd)/flash_logs"
if command -v xdg-open >/dev/null 2>&1; then
  log "Opening logs folder: $OPEN_DIR"
  xdg-open "$OPEN_DIR" >/dev/null 2>&1 || log "Could not open folder via xdg-open."
else
  log "Open logs folder manually at: $OPEN_DIR"
fi

if [[ -n "${SERIAL:-}" ]]; then
  echo "Reset board now that all is done.."
  if "$COMMANDER" adapter reset --serialno "$SERIAL" >/dev/null 2>&1; then
    :
  else
    :
  fi
fi

