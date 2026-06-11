#!/usr/bin/env bash

#
# Support arguments:
#   -f <file>               Execute file on host, print the result and exit
#   -c <command>            Execute command on host, print the result and exit
#   -C <command in base64>  Execute command on host, print the result and exit
#   -v <level>              Verbose mode: 1 - verbose, 2 - super verbose
#   -e <NAME=B64> -e ...    Environment variables (B64 is base64 encoded string)
#   -b <BASE64> -b ...      Base64 encoded bash command
#   -H <HOME path>          HOME path. Will be $HOME on the host.
#   -X <XDG path>           XDG_* path
#

# Base64 decoder function
decode_b64() {
  if command -v base64 >/dev/null 2>&1; then
    echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 --decode 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then
    echo "$1" | openssl enc -d -base64 2>/dev/null
  else
    # Fallback to python if available
    python3 -c "import base64; print(base64.b64decode('$1').decode('utf-8'))" 2>/dev/null
  fi
}

EXECUTE_FILE=""
EXECUTE_COMMAND=""
EXECUTE_COMMAND_B64=""
VERBOSE=""
declare -a ENV_VARS
declare -a EBASH

while getopts f:c:C:v:e:b:H:X: option
do
  case "${option}"
  in
    f) EXECUTE_FILE=${OPTARG};;
    c) EXECUTE_COMMAND=${OPTARG};;
    C) EXECUTE_COMMAND_B64=${OPTARG};;
    v) VERBOSE=${OPTARG};;
    e) ENV_VARS+=("$OPTARG");;
    b) EBASH+=("$OPTARG");;
    H) HOMEPATH=${OPTARG};;
    X) XDGPATH=${OPTARG};;
  esac
done

if [[ $VERBOSE != '' ]]; then
  export XXH_VERBOSE=$VERBOSE
fi

# Set up XXH_HOME
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
export XXH_HOME=`readlink -f $CURRENT_DIR/../../../..`

# Apply HOMEPATH override if set
if [[ $HOMEPATH != '' ]]; then
  homerealpath=`readlink -f $HOMEPATH`
  if [[ -d $homerealpath ]]; then
    export HOME=$homerealpath
  fi
fi

# Set environment variables passed by xxh/zzh
for item in "${ENV_VARS[@]}"; do
  if [[ $item == *"="* ]]; then
    key="${item%%=*}"
    b64_val="${item#*=}"
    val=$(decode_b64 "$b64_val")
    export "$key"="$val"
  else
    export "$item"=""
  fi
done

# Run any base64 encoded bash commands passed by xxh/zzh (prerun plugins etc.)
for b64_cmd in "${EBASH[@]}"; do
  cmd=$(decode_b64 "$b64_cmd")
  if [[ $cmd != '' ]]; then
    eval "$cmd"
  fi
done

# Path to the portable Nushell binary
NU_BIN="$CURRENT_DIR/bin/nu"

# Path to plugin registry config file
PLUGIN_CONFIG="$XXH_HOME/plugin.msgpackz"

# Find and register all nu_plugin_* executables
# 1. Look in shell's own bin directory (shipped plugins)
if [[ -d "$CURRENT_DIR/bin" ]]; then
  for p in "$CURRENT_DIR/bin"/nu_plugin_*; do
    if [[ -x "$p" ]]; then
      "$NU_BIN" --plugin-config "$PLUGIN_CONFIG" -c "plugin add '$p'" >/dev/null 2>&1
    fi
  done
fi

# 2. Look in external plugins directory
PLUGINS_DIR="$XXH_HOME/.zzh/plugins"
if [[ -d "$PLUGINS_DIR" ]]; then
  find "$PLUGINS_DIR" -type f -name "nu_plugin_*" -perm -u+x 2>/dev/null | while read -r p; do
    "$NU_BIN" --plugin-config "$PLUGIN_CONFIG" -c "plugin add '$p'" >/dev/null 2>&1
  done
fi

if [[ $EXECUTE_COMMAND_B64 != '' ]]; then
  cmd=$(decode_b64 "$EXECUTE_COMMAND_B64")
  exec "$NU_BIN" --plugin-config "$PLUGIN_CONFIG" -c "$cmd"
elif [[ $EXECUTE_COMMAND != '' ]]; then
  exec "$NU_BIN" --plugin-config "$PLUGIN_CONFIG" -c "$EXECUTE_COMMAND"
elif [[ $EXECUTE_FILE != '' ]]; then
  exec "$NU_BIN" --plugin-config "$PLUGIN_CONFIG" "$EXECUTE_FILE"
else
  # Launch interactive Nushell
  exec "$NU_BIN" --plugin-config "$PLUGIN_CONFIG"
fi
