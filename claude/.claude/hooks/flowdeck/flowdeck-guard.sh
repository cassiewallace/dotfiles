#!/bin/bash
# FlowDeck Guard - Claude Code Hook
# Prevents direct use of Apple CLI tools that FlowDeck replaces
#
# This hook blocks commands like xcodebuild, xcrun simctl, xcrun devicectl,
# and system log CLIs, and suggests the equivalent FlowDeck command instead.
#
# Blocked categories (only when tool is in command position):
#   - xcodebuild: build, test, clean, -list
#   - xcrun simctl: list, boot, shutdown, erase, create, clone, delete,
#     install, launch, terminate, uninstall, io, ui, location, addmedia,
#     spawn log, log, runtime, openurl
#   - xcrun devicectl: list devices, device install/uninstall/launch/terminate
#   - open *.app (build outputs only, not /Applications/ or /System/)
#
# Allowed (never blocked):
#   - xcodebuild: -version, -showsdks, -showBuildSettings, -showDestinations
#   - xcrun: notarytool, altool, stapler, actool, swift-symbolicator, etc.
#   - xcrun simctl: status_bar, push, pair, getenv, get_app_container, etc.
#   - xcrun devicectl: device info, list availableRuntimes, etc.
#   - xcode-select, swift build/test/package, open -a Simulator
#   - log show, log stream (system diagnostics)
#   - Commands containing tool names as arguments (echo, grep, cat, etc.)

set -e

# Read JSON input from stdin
INPUT=$(cat)

# Extract the command from JSON
# Format: {"tool_input": {"command": "..."}}
COMMAND=""
if [ -x /usr/bin/python3 ]; then
    COMMAND=$(
        FLOWDECK_GUARD_INPUT="$INPUT" /usr/bin/python3 -c 'import json, os
try:
    data = json.loads(os.environ.get("FLOWDECK_GUARD_INPUT", ""))
    command = data.get("tool_input", {}).get("command", "")
    if isinstance(command, str):
        print(command)
except Exception:
    pass' 2>/dev/null || true
    )
fi

if [ -z "$COMMAND" ] && command -v jq >/dev/null 2>&1; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi

if [ -z "$COMMAND" ]; then
    COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//' | sed 's/"$//')
fi

# If no command found, allow execution
if [ -z "$COMMAND" ]; then
    exit 0
fi

# Early exit: skip all checks if the command doesn't contain any blocked tool names
if ! echo "$COMMAND" | grep -qE 'xcodebuild|xcrun|^open\s+.*\.app(\s|/|$)'; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Extract the "effective command" — strip leading shell operators so we match
# on the actual tool being invoked, not arguments to echo/grep/cat/etc.
# For piped/chained commands we check each segment.
# ---------------------------------------------------------------------------
# Split on ;, &&, ||, | and check each segment independently.
# We only block when the tool name appears in command position (first word of
# a segment), not when it appears as an argument to another command.
# ---------------------------------------------------------------------------

# Helper: strip one leading VAR=value assignment from a string.
# Handles: VAR=simple, VAR="quoted val", VAR='quoted val', VAR=$(cmd args),
#          VAR=$(cmd $(nested)), VAR=$((expr))
# Returns the remainder (after the assignment and its trailing space).
# If there is no leading assignment, returns the input unchanged.
strip_one_assignment() {
    local s="$1"
    # Must start with NAME=
    if ! echo "$s" | grep -qE '^[A-Za-z_][A-Za-z_0-9]*='; then
        echo "$s"
        return
    fi
    # Remove the NAME= prefix
    local after_eq
    after_eq=$(echo "$s" | sed 's/^[A-Za-z_][A-Za-z_0-9]*=//')
    local first_char
    first_char=$(printf '%.1s' "$after_eq")
    case "$first_char" in
        '"')
            # Double-quoted value: skip to closing unescaped "
            after_eq="${after_eq#\"}"
            while true; do
                case "$after_eq" in
                    "") echo ""; return ;;
                    \\?*) after_eq="${after_eq#\\?}" ;;
                    \"*) after_eq="${after_eq#\"}"; break ;;
                    *) after_eq="${after_eq#?}" ;;
                esac
            done
            # Strip leading whitespace after the closing quote
            echo "$after_eq" | sed 's/^[[:space:]]*//'
            ;;
        "'")
            # Single-quoted value: skip to closing '
            after_eq="${after_eq#\'}"
            after_eq="${after_eq#*\'}"
            echo "$after_eq" | sed 's/^[[:space:]]*//'
            ;;
        '$')
            # Command substitution $(...) or arithmetic $((...))
            # Count parentheses depth to handle nesting
            local rest="${after_eq#\$}"
            if [ "${rest#(}" != "$rest" ]; then
                rest="${rest#(}"
                local depth=1
                while [ $depth -gt 0 ] && [ -n "$rest" ]; do
                    case "$rest" in
                        '('*) depth=$((depth + 1)); rest="${rest#(}" ;;
                        ')'*) depth=$((depth - 1)); rest="${rest#)}" ;;
                        *) rest="${rest#?}" ;;
                    esac
                done
                echo "$rest" | sed 's/^[[:space:]]*//'
            else
                # $VAR or other $ form — treat like simple value
                echo "$after_eq" | sed 's/^[^ ]*//' | sed 's/^[[:space:]]*//'
            fi
            ;;
        *)
            # Simple unquoted value — everything up to first whitespace
            echo "$after_eq" | sed 's/^[^ ]*//' | sed 's/^[[:space:]]*//'
            ;;
    esac
}

# Helper: strip shell prefixes from a command segment to find the real command.
# Removes: VAR=val assignments, sudo [...], env [...], time, command, nice [...], nohup, exec, eval
# Handles path-qualified wrappers (/usr/bin/sudo, /usr/bin/env, etc.)
# Handles wrapper flags (sudo -u root, nice -n 10, env -u VAR, etc.)
# Handles shell -c wrappers (bash -c '...', sh -c '...', zsh -c '...')
strip_prefixes() {
    local seg="$1"
    local prev=""
    # Loop until no more prefixes can be stripped (prev == seg means stable)
    while [ "$seg" != "$prev" ]; do
        prev="$seg"
        # Strip leading VAR=val pairs (handles simple, quoted, and $(cmd) forms)
        while echo "$seg" | grep -qE '^[A-Za-z_][A-Za-z_0-9]*='; do
            local stripped
            stripped=$(strip_one_assignment "$seg")
            # If nothing changed, we're stuck (assignment is the entire string)
            [ "$stripped" = "$seg" ] && break
            # If stripped is empty, the assignment consumed everything
            [ -z "$stripped" ] && seg="" && break
            seg="$stripped"
        done
        # Strip known wrappers — match bare name or path-qualified
        # (e.g. sudo, /usr/bin/sudo, /usr/bin/env)
        if echo "$seg" | grep -qE '^(/[^ ]*/)?(sudo|env|time|command|nice|nohup|exec|eval)(\s|$)'; then
            # Capture the wrapper name (without path)
            # Extract first word, then strip path prefix
            local wrapper
            wrapper=$(echo "$seg" | sed 's/ .*//' | sed 's|^.*/||')
            # Remove the wrapper name (with optional path)
            seg=$(echo "$seg" | sed 's/^[^ ]* *//')
            # Strip flags and VAR=val pairs after the wrapper.
            # Known flags that take a separate operand (short and long forms):
            #   sudo: -u/--user, -g/--group, -C/--close-from, -D/--chdir,
            #         -R/--chroot, -p/--prompt, -h/--host, -T/--command-timeout,
            #         -U/--other-user
            #   nice: -n NUM
            #   env: -u/--unset, -C/--chdir, -P altpath, -S/--split-string
            while true; do
                if echo "$seg" | grep -qE '^-\S+(\s|$)'; then
                    # Flag token
                    local token
                    token=$(echo "$seg" | sed 's/ .*//')
                    seg=$(echo "$seg" | sed 's/^[^ ]* *//')
                    # Consume argument for flags that take one
                    case "$wrapper" in
                        sudo)
                            case "$token" in -u|-g|-C|-D|-R|-p|-h|-T|-U|--user|--group|--close-from|--chdir|--chroot|--prompt|--host|--command-timeout|--other-user)
                                [ -n "$seg" ] && seg=$(echo "$seg" | sed 's/^[^ ]* *//')
                            ;; esac
                            # Handle grouped short flags containing operand flags
                            # e.g. -ABu means -A -B -u, so -u still needs its operand consumed
                            if echo "$token" | grep -qE '^-[A-Za-z]*[ugCDRphTU]$' && ! echo "$token" | grep -qE '^-[ugCDRphTU]$'; then
                                # Last char is an operand-taking flag, consume operand
                                [ -n "$seg" ] && seg=$(echo "$seg" | sed 's/^[^ ]* *//')
                            fi
                            ;;
                        nice)
                            case "$token" in -n)
                                [ -n "$seg" ] && seg=$(echo "$seg" | sed 's/^[^ ]* *//')
                            ;; esac
                            ;;
                        env)
                            case "$token" in -u|-C|-P|--unset|--chdir)
                                # Simple operand: consume next token
                                [ -n "$seg" ] && seg=$(echo "$seg" | sed 's/^[^ ]* *//')
                            ;; esac
                            case "$token" in -S|--split-string)
                                # -S takes a string that env splits into cmd+args.
                                # If quoted, the string IS the command to run.
                                if [ -n "$seg" ]; then
                                    local fc
                                    fc=$(printf '%.1s' "$seg")
                                    case "$fc" in
                                        "'"*|'"'*)
                                            # Strip opening quote, content up to close is the command
                                            local inner
                                            inner="${seg#?}"
                                            inner=$(echo "$inner" | sed "s/${fc}.*//")
                                            seg="$inner"
                                            ;;
                                        *)
                                            # Unquoted: rest of segment is the split-string
                                            # (env splits on whitespace, so effective cmd is first word)
                                            ;;
                                    esac
                                fi
                            ;; esac
                            ;;
                    esac
                elif echo "$seg" | grep -qE '^[A-Za-z_][A-Za-z_0-9]*='; then
                    # VAR=val after wrapper (e.g. env DEVELOPER_DIR=/path cmd)
                    local stripped
                    stripped=$(strip_one_assignment "$seg")
                    [ "$stripped" = "$seg" ] && break
                    [ -z "$stripped" ] && seg="" && break
                    seg="$stripped"
                else
                    break
                fi
            done
        fi
        # Handle shell -c wrappers (bash -c '...', sh -c '...', zsh -c '...')
        # Extract the -c argument as the effective command
        if echo "$seg" | grep -qE '^(/[^ ]*/)?(bash|sh|zsh)\s'; then
            local shell_args
            shell_args=$(echo "$seg" | sed 's/^[^ ]* *//')
            # Look for -c flag (possibly after other flags like -l)
            local found_c=""
            local sa="$shell_args"
            while [ -n "$sa" ]; do
                local word
                word=$(echo "$sa" | sed 's/ .*//')
                sa=$(echo "$sa" | sed 's/^[^ ]* *//')
                if [ "$word" = "-c" ]; then
                    found_c=1
                    break
                fi
                # Check for combined flags containing c (e.g. -lc, -ilc)
                if echo "$word" | grep -qE '^-[a-zA-Z]*c$'; then
                    found_c=1
                    break
                fi
                # Skip other flag groups (e.g. -l, -i, -le) and long options (e.g. --noprofile, --login)
                if echo "$word" | grep -qE '^-[a-zA-Z]+$|^--[a-zA-Z]'; then
                    continue
                fi
                # Not a flag and not -c, stop looking
                break
            done
            if [ -n "$found_c" ] && [ -n "$sa" ]; then
                # The next token is the command string; strip surrounding quotes
                local cmd_str="$sa"
                # Remove leading/trailing single or double quotes
                cmd_str=$(echo "$cmd_str" | sed "s/^['\"]//; s/['\"]$//")
                seg="$cmd_str"
            fi
        fi
    done
    echo "$seg"
}

# Helper: check if a command segment starts with a blocked tool
# Returns the segment with leading whitespace stripped
segments_starting_with_tool() {
    local tool="$1"
    # Split COMMAND on shell operators and find segments where the tool is the command
    echo "$COMMAND" | tr ';' '\n' | sed 's/&&/\n/g; s/||/\n/g; s/|/\n/g; s/&/\n/g' | \
        sed 's/^[[:space:]]*//' | while IFS= read -r seg; do
            local effective
            effective=$(strip_prefixes "$seg")
            # Normalize path-qualified commands (e.g. /usr/bin/xcodebuild → xcodebuild)
            local normalized
            normalized=$(echo "$effective" | sed 's|^/[^ ]*/||')
            if echo "$normalized" | grep -qE "^${tool}(\s|$)"; then
                echo "$normalized"
            fi
        done
}

# Check if any segment of the command starts with the given tool
has_tool_segment() {
    local tool="$1"
    local result
    result=$(segments_starting_with_tool "$tool")
    [ -n "$result" ]
}

# Helper function to block with message
block_with_suggestion() {
    local blocked_cmd="$1"
    local suggestion="$2"
    echo "BLOCKED: $blocked_cmd" >&2
    echo "" >&2
    echo "FlowDeck provides this functionality. Use instead:" >&2
    echo "  $suggestion" >&2
    echo "" >&2
    echo "FlowDeck is your primary tool for iOS/macOS development." >&2
    echo "See 'flowdeck --help' for more commands." >&2
    exit 2
}

# ============================================================================
# xcodebuild commands
# FlowDeck replaces: -list, build, test, clean
# ============================================================================

# For xcodebuild, extract the segment(s) that start with xcodebuild
XCBUILD_SEG=$(segments_starting_with_tool "xcodebuild")

if [ -n "$XCBUILD_SEG" ]; then
    # Block: xcodebuild -list → flowdeck context/scheme list
    if echo "$XCBUILD_SEG" | grep -qE '\-list(\s|$)'; then
        block_with_suggestion "xcodebuild -list" "flowdeck context --json  OR  flowdeck scheme list"
    fi

    # Block: xcodebuild build → flowdeck build
    if echo "$XCBUILD_SEG" | grep -qE '\s+build(\s|$)'; then
        block_with_suggestion "xcodebuild build" "flowdeck build"
    fi

    # Block: xcodebuild test → flowdeck test
    if echo "$XCBUILD_SEG" | grep -qE '\s+test(\s|$)'; then
        block_with_suggestion "xcodebuild test" "flowdeck test"
    fi

    # Block: xcodebuild clean → flowdeck clean
    if echo "$XCBUILD_SEG" | grep -qE '\s+clean(\s|$)'; then
        block_with_suggestion "xcodebuild clean" "flowdeck clean"
    fi
fi

# ============================================================================
# xcrun simctl commands — specific suggestions first, then catch-all
# ============================================================================

# For xcrun simctl, extract segments where simctl is the immediate subcommand
SIMCTL_SEG=$(segments_starting_with_tool "xcrun" | grep -E '^xcrun\s+simctl\s' || true)

if [ -n "$SIMCTL_SEG" ]; then
    # Block: xcrun simctl list → flowdeck simulator list
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+list'; then
        block_with_suggestion "xcrun simctl list" "flowdeck simulator list [--json]"
    fi

    # Block: xcrun simctl boot → flowdeck simulator boot
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+boot'; then
        block_with_suggestion "xcrun simctl boot" "flowdeck simulator boot <udid>"
    fi

    # Block: xcrun simctl shutdown → flowdeck simulator shutdown
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+shutdown'; then
        block_with_suggestion "xcrun simctl shutdown" "flowdeck simulator shutdown <udid>"
    fi

    # Block: xcrun simctl erase → flowdeck simulator erase
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+erase'; then
        block_with_suggestion "xcrun simctl erase" "flowdeck simulator erase <udid>"
    fi

    # Block: xcrun simctl create → flowdeck simulator create
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+create'; then
        block_with_suggestion "xcrun simctl create" "flowdeck simulator create --name <name> --device-type <type> --runtime <runtime>"
    fi

    # Block: xcrun simctl clone → flowdeck simulator clone
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+clone'; then
        block_with_suggestion "xcrun simctl clone" "flowdeck simulator clone <source> --name <name>"
    fi

    # Block: xcrun simctl delete → flowdeck simulator delete/prune
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+delete'; then
        block_with_suggestion "xcrun simctl delete" "flowdeck simulator delete <udid>  OR  flowdeck simulator prune"
    fi

    # Block: xcrun simctl install → flowdeck run
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+install'; then
        block_with_suggestion "xcrun simctl install" "flowdeck run (handles install automatically)"
    fi

    # Block: xcrun simctl launch → flowdeck run
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+launch'; then
        block_with_suggestion "xcrun simctl launch" "flowdeck run"
    fi

    # Block: xcrun simctl terminate → flowdeck stop
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+terminate'; then
        block_with_suggestion "xcrun simctl terminate" "flowdeck stop"
    fi

    # Block: xcrun simctl uninstall → flowdeck uninstall
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+uninstall'; then
        block_with_suggestion "xcrun simctl uninstall" "flowdeck uninstall <bundle-id>"
    fi

    # Block: xcrun simctl io screenshot → flowdeck ui simulator screen
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+io.*screenshot'; then
        block_with_suggestion "xcrun simctl io screenshot" "flowdeck ui simulator screen -S <name-or-udid> --output <path>"
    fi

    # Block: xcrun simctl io recordVideo → flowdeck ui simulator record
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+io.*recordVideo'; then
        block_with_suggestion "xcrun simctl io recordVideo" "flowdeck ui simulator record -S <name-or-udid> --output <path>"
    fi

    # Block: xcrun simctl ui ... appearance → flowdeck ui simulator set-appearance
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+ui\s+.*\s+appearance'; then
        block_with_suggestion "xcrun simctl ui ... appearance" "flowdeck ui simulator set-appearance <light|dark> -S <name-or-udid>"
    fi

    # Block: xcrun simctl location → flowdeck simulator location set
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+location'; then
        block_with_suggestion "xcrun simctl location" "flowdeck simulator location set <lat,lon> [--udid <udid>]"
    fi

    # Block: xcrun simctl addmedia → flowdeck simulator media add
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+addmedia'; then
        block_with_suggestion "xcrun simctl addmedia" "flowdeck simulator media add <file> [--udid <udid>]"
    fi

    # Block: xcrun simctl spawn <udid> log → flowdeck logs
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+spawn\s+.*\s+log(\s|$)'; then
        block_with_suggestion "xcrun simctl spawn ... log" "flowdeck logs <app-id>  OR  flowdeck run --log"
    fi

    # Block: xcrun simctl log → flowdeck logs
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+log(\s|$)'; then
        block_with_suggestion "xcrun simctl log" "flowdeck logs <app-id>  OR  flowdeck run --log"
    fi

    # Block: xcrun simctl runtime → flowdeck simulator runtime
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+runtime'; then
        block_with_suggestion "xcrun simctl runtime" "flowdeck simulator runtime list/create/delete/available"
    fi

    # Block: xcrun simctl openurl → flowdeck ui simulator open-url
    if echo "$SIMCTL_SEG" | grep -qE 'simctl\s+openurl'; then
        block_with_suggestion "xcrun simctl openurl" "flowdeck ui simulator open-url <url> -S <name-or-udid>"
    fi

    # No catch-all: only block subcommands FlowDeck actually replaces
fi

# ============================================================================
# xcrun devicectl commands — specific suggestions first, then catch-all
# ============================================================================

# For xcrun devicectl, extract segments that start with xcrun and contain devicectl
DEVCTL_SEG=$(segments_starting_with_tool "xcrun" | grep -E '^xcrun\s+devicectl\s' || true)

if [ -n "$DEVCTL_SEG" ]; then
    # Block: xcrun devicectl list devices → flowdeck device list
    if echo "$DEVCTL_SEG" | grep -qE 'devicectl\s+list\s+devices'; then
        block_with_suggestion "xcrun devicectl list devices" "flowdeck device list [--json]"
    fi

    # Block: xcrun devicectl device install → flowdeck device install
    if echo "$DEVCTL_SEG" | grep -qE 'devicectl\s+device\s+install'; then
        block_with_suggestion "xcrun devicectl device install" "flowdeck device install <udid> <app-path>"
    fi

    # Block: xcrun devicectl device uninstall → flowdeck device uninstall
    if echo "$DEVCTL_SEG" | grep -qE 'devicectl\s+device\s+uninstall'; then
        block_with_suggestion "xcrun devicectl device uninstall" "flowdeck device uninstall <udid> <bundle-id>"
    fi

    # Block: xcrun devicectl device process launch → flowdeck device launch
    if echo "$DEVCTL_SEG" | grep -qE 'devicectl\s+device\s+process\s+launch'; then
        block_with_suggestion "xcrun devicectl device process launch" "flowdeck device launch <udid> <bundle-id>"
    fi

    # Block: xcrun devicectl device process terminate → flowdeck stop
    if echo "$DEVCTL_SEG" | grep -qE 'devicectl\s+device\s+process\s+terminate'; then
        block_with_suggestion "xcrun devicectl device process terminate" "flowdeck stop"
    fi

    # No catch-all: only block subcommands FlowDeck actually replaces
fi

# ============================================================================
# open command for built apps
# ============================================================================

# Block: open *.app → flowdeck run
# Only block build-output .app bundles, NOT system/installed applications.
# Exclude: /Applications/, /System/, ~/Applications/, and -a flag (open -a ...)
if echo "$COMMAND" | grep -qE '^open\s+.*\.app(/Contents)?(/MacOS)?(/[^/]+)?(\s|$)'; then
    # Allow system applications and "open -a" syntax
    if ! echo "$COMMAND" | grep -qE '^open\s+(-a\s|/Applications/|/System/|~/Applications/)'; then
        block_with_suggestion "open <app>.app" "flowdeck run --simulator none  (for macOS apps)"
    fi
fi

# ============================================================================
# System log CLIs — only block app-targeted log commands
# ============================================================================

# Note: bare `log show` and `log stream` are general macOS diagnostic tools
# used for system processes (tccd, launchd, etc.) and are NOT blocked.
# The skill instructions guide agents to use `flowdeck logs` for app logs.
# Only xcrun simctl log/spawn log variants are blocked (see simctl section).

# ============================================================================
# ALLOWED commands (not blocked)
# ============================================================================
# xcodebuild: -version, -showsdks, -showBuildSettings, -showDestinations
# xcodebuild: implicit builds (without explicit build/test/clean action)
# xcode-select, swift build/test/package, open -a Simulator

# If we reach here, the command is allowed
exit 0
