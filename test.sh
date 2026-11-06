#!/bin/bash
# Tests against a fake Claude directory (temporary HOME), with stubs for claude and
# notify-send. Doesn't touch your sway session, Claude sessions or trash.
# - listing, details, keys: the picker in a detached tmux session
# - sway window mode: a headless nested sway, once per terminal (alacritty, foot)
set -euo pipefail
cd "$(dirname "$0")"
CS=$PWD/claude-sessions

H=$(mktemp -d)
R=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" cs.XXXX)  # short: fzf's socket path is limited to 108 chars
T=claude-sessions-test-$$
pids=()
cleanup() {
    tmux kill-session -t "$T" 2>/dev/null || true
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    rm -rf "$H" "$R"
}
trap cleanup EXIT
fail=0
check() {
    if [[ $2 == "$3" ]]; then echo "  PASS $1"; else echo "  FAIL $1: got '$2', expected '$3'"; fail=1; fi
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- fake sessions: two stopped, one running (a sleep process), one headless (claude -p)
C=$H/.claude
mkdir -p "$C/projects/-p" "$C/sessions" "$H/proj" "$H/bin"
session() {  # id title entrypoint age
    local f=$C/projects/-p/$1.jsonl
    printf '{"type":"user","cwd":"%s","entrypoint":"%s","gitBranch":"main","timestamp":"2026-01-02T03:04:05Z","message":{"role":"user","content":"first prompt of %s"}}\n{"type":"ai-title","aiTitle":"%s"}\n' \
        "$H/proj" "$3" "$2" "$2" >"$f"
    touch -d "$4" "$f"
}
running() {  # id pid
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","status":"idle"}\n' \
        "$2" "$1" "$H/proj" "$(awk '{print $22}' "/proc/$2/stat")" >"$C/sessions/$2.json"
}
session r1 Running cli now
session s2 Beta cli '1 hour ago'
session s1 Alpha cli '2 hours ago'
session h1 Headless sdk-cli now
mkdir -p "$C/projects/-p/s1/subagents" "$C/file-history/s1" "$C/session-env/s1"
sleep 600 &
pids+=($!)
running r1 $!
printf '#!/bin/sh\necho "$@" >>%s/notify.log\n' "$H" >"$H/bin/notify-send"
printf '#!/bin/sh\necho "$PWD $*" >>%s/claude.log\n' "$H" >"$H/bin/claude"
chmod +x "$H/bin/notify-send" "$H/bin/claude"
ENV=(env -u TMUX -u SWAYSOCK HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_RUNTIME_DIR="$R" PATH="$H/bin:$PATH")

echo "listing"
list=$("${ENV[@]}" "$CS" --list all | plain)
check "stopped and running sessions listed" "$(grep -c '●' <<<"$list")" 3
check "headless session hidden" "$(grep -c Headless <<<"$list" || true)" 0
check "sessions under their directory" "$(grep -c '^dir:/~/proj' <<<"$list")" 1
check "newest first" "$(cut -f1 <<<"$list" | tr '\n' ' ')" "dir:/~/proj r1 s2 s1 "
check "running only" "$("${ENV[@]}" "$CS" --list running | plain | grep -c '●')" 1

echo "details"
info=$("${ENV[@]}" "$CS" --info r1 | plain)
check "status" "$(grep -c 'running (pid' <<<"$info")" 1
check "branch" "$(grep '^branch' <<<"$info" | awk '{print $2}')" main
check "first prompt" "$(grep -c 'first prompt of Running' <<<"$info")" 1

screen() { tmux capture-pane -p -t "$T"; }
wait_for() { for _ in $(seq 25); do screen | grep -q -- "$1" && return 0; sleep 0.2; done; echo "  timeout waiting for '$1'"; return 1; }
picker() { tmux new-session -d -s "$T" -x 160 -y 20 "$(printf '%q ' "${ENV[@]}" "$@")"; }

echo "plain mode (any terminal, no sway)"
picker "$CS"
wait_for Running
check "starts with running sessions only" "$(screen | grep -c -e Alpha -e Beta || true)" 0
wait_for 'status   '
check "starts on the first session, details pane shown" "$(screen | grep -c 'status   ')" 1
before=$(screen)
tmux send-keys -t "$T" Tab
sleep 0.5
check "tab does nothing" "$(screen)" "$before"
tmux send-keys -t "$T" Enter
sleep 0.5
check "enter on a running session without sway does nothing" "$(screen)" "$before"
tmux send-keys -t "$T" C-a
wait_for 'all>'
wait_for Alpha
check "ctrl-a shows all sessions" "$(screen | grep -c -e Alpha -e Beta)" 2
tmux send-keys -t "$T" Down Down   # Running -> Beta -> Alpha
sleep 0.5
tmux send-keys -t "$T" Enter
for _ in $(seq 25); do [[ -s $H/claude.log ]] && break; sleep 0.2; done
check "enter on a stopped session resumes it here" "$(cat "$H/claude.log" 2>/dev/null)" "$H/proj --resume s1"
tmux kill-session -t "$T" 2>/dev/null || true

echo "deleting (window mode picker, cursor read from its fzf socket)"
picker "$CS" --window
wait_for Running
current() { curl -s --unix-socket "$R/claude-sessions.sock" 'http://localhost?limit=0' | jq -r '.current.text | split("\t")[0]'; }
sleep 0.5
check "starts on the first session" "$(current)" r1
tmux send-keys -t "$T" C-a
wait_for Alpha
for _ in 1 2 3 4; do [[ $(current) == r1 ]] && break; tmux send-keys -t "$T" Down; sleep 0.2; done
check "cursor on the running session" "$(current)" r1
sleep 0.3
check "no Delete hint on a running session" "$(screen | grep -c 'del: move' || true)" 0
tmux send-keys -t "$T" DC
sleep 1
check "Delete keeps a running session" "$(ls "$C/projects/-p" | tr '\n' ' ')" "h1.jsonl r1.jsonl s1 s1.jsonl s2.jsonl "
check "notification" "$(cat "$H/notify.log")" "claude-sessions 1 running session(s) not deleted"
for _ in 1 2 3 4; do [[ $(current) == s1 ]] && break; tmux send-keys -t "$T" Down; sleep 0.2; done
check "cursor on a stopped session" "$(current)" s1
sleep 0.3
check "Delete hint on a stopped session" "$(screen | grep -c 'del: move')" 1
tmux send-keys -t "$T" DC
wait_for ' 3/3 '
for _ in $(seq 25); do screen | grep -q "● Alpha" || break; sleep 0.2; done  # rows redraw after the count
check "Delete trashes all files of a stopped session" "$(cd "$H/.local/share/Trash/files" && ls | sort | tr '\n' ' ')" "s1 s1.2 s1.3 s1.jsonl "
check "trashed session gone from the list" "$(screen | grep -c "● Alpha" || true)" 0
tmux kill-session -t "$T" 2>/dev/null || true

echo "folder lines are skipped"
H2=$H/skip
C2=$H2/.claude
mkdir -p "$C2/sessions"
n=0
for spec in x1:p/x:Alpha x2:p/x:Bravo y1:p/y:Charlie q1:q:Delta; do
    IFS=: read -r id dir title <<<"$spec"
    mkdir -p "$H2/$dir" "$C2/projects/-$id"
    printf '{"type":"user","cwd":"%s","entrypoint":"cli"}\n{"type":"ai-title","aiTitle":"%s"}\n' "$H2/$dir" "$title" >"$C2/projects/-$id/$id.jsonl"
    touch -d "$((n++)) minutes ago" "$C2/projects/-$id/$id.jsonl"
    sleep 600 &
    pids+=($!)
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s"}\n' "$!" "$id" "$H2/$dir" "$(awk '{print $22}' "/proc/$!/stat")" >"$C2/sessions/$!.json"
done
check "tree has folder lines between sessions" "$(env HOME="$H2" "$CS" --list running | cut -f1 | tr '\n' ' ')" "dir:/~ dir:/~/p dir:/~/p/x x1 x2 dir:/~/p/y y1 dir:/~/q q1 "
tmux new-session -d -s "$T" -x 160 -y 20 "$(printf '%q ' env -u TMUX -u SWAYSOCK HOME="$H2" XDG_RUNTIME_DIR="$R" PATH="$H/bin:$PATH" "$CS" --window)"
wait_for Delta
sleep 0.5
check "starts on the first session, not a folder" "$(current)" x1
moves() {  # key... -> current item after each key
    local out=()
    for k in "$@"; do tmux send-keys -t "$T" "$k"; sleep 0.4; out+=("$(current)"); done
    echo "${out[*]}"
}
check "down skips folders" "$(moves Down Down Down Down)" "x2 y1 q1 q1"
check "up skips folders, stops at the first session" "$(moves Up Up Up Up)" "y1 x2 x1 x1"
tmux send-keys -t "$T" C-j C-j; sleep 0.8
check "ctrl-j skips folders too" "$(current)" y1
tmux send-keys -t "$T" r u n n i n g; sleep 0.8
check "the hidden status field isn't searchable" "$(curl -s --unix-socket "$R/claude-sessions.sock" 'http://localhost?limit=0' | jq .matchCount)" 0
tmux send-keys -t "$T" C-u D e l t; sleep 0.8
check "filter result: cursor on a session" "$(current)" q1
tmux send-keys -t "$T" C-u '/~/p/' ; sleep 1
check "filter showing only folders: fzf still responds" "$(curl -s -m 2 --unix-socket "$R/claude-sessions.sock" 'http://localhost?limit=0' | jq -r .query)" "/~/p/"
tmux kill-session -t "$T" 2>/dev/null || true
rm -f "$R/claude-sessions.sock"

# --- sway window mode in a headless nested sway
window_mode() {  # terminal
    local term=$1 swaypid sock="" wl before n
    echo "sway window mode ($term)"
    printf '%s\n' 'for_window [app_id="^claude-sessions$"] floating enable, move scratchpad' >"$R/sway.conf"
    before=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-[0-9]* 2>/dev/null | grep -v lock || true)
    env -u WAYLAND_DISPLAY -u SWAYSOCK -u DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
        sway -c "$R/sway.conf" >"$R/sway.log" 2>&1 &
    swaypid=$!
    pids+=($swaypid)
    for _ in $(seq 50); do sock=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*."$swaypid".sock 2>/dev/null || true); [[ $sock ]] && break; sleep 0.1; done
    wl=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-[0-9]* | grep -v lock | grep -vxF -f <(echo "$before") | head -1 || true)
    [[ $sock && $wl ]] || { echo "  FAIL nested sway didn't start"; fail=1; return; }
    local W=(env -u TMUX SWAYSOCK="$sock" WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/$wl" HOME="$H" XDG_DATA_HOME="$H/.local/share"
             XDG_RUNTIME_DIR="$R" PATH="$H/bin:$PATH" CLAUDE_SESSIONS_TERMINAL="$term")
    tree() { "${W[@]}" swaymsg -t get_tree; }
    picker_state() { tree | jq -c '[.. | select(.app_id? == "claude-sessions") | {visible, focused}] | .[0]'; }

    # a running session in its own terminal window
    rm -f "$H/w.pid"
    if [[ $term == foot ]]; then
        "${W[@]}" foot sh -c "echo \$\$ >$H/w.pid; exec sleep 600" >/dev/null 2>&1 &
    else
        "${W[@]}" alacritty -e sh -c "echo \$\$ >$H/w.pid; exec sleep 600" >/dev/null 2>&1 &
    fi
    for _ in $(seq 50); do [[ -s $H/w.pid ]] && break; sleep 0.1; done
    session w1 Windowed cli now
    running w1 "$(cat "$H/w.pid")"
    local wcon
    wcon=$(tree | jq --argjson p "$(cat "$H/w.pid")" 'first(.. | select(.pid? and .app_id? != "claude-sessions") | .id)')

    "${W[@]}" "$CS" --start
    check "--start: hidden in the scratchpad" "$(picker_state)" '{"visible":false,"focused":false}'
    "${W[@]}" "$CS" --toggle
    sleep 0.5
    check "--toggle shows and focuses it" "$(picker_state)" '{"visible":true,"focused":true}'
    for _ in $(seq 25); do curl -s --unix-socket "$R/claude-sessions.sock" 'http://localhost?limit=0' | grep -q '"totalCount":[1-9]' && break; sleep 0.2; done
    n=$("${W[@]}" "$CS" --list running | grep -n '^w1	' | cut -d: -f1)
    curl -s --unix-socket "$R/claude-sessions.sock" http://localhost -d "pos($n)"
    sleep 0.3
    # the same action as the Enter binding of the window mode
    curl -s --unix-socket "$R/claude-sessions.sock" http://localhost --data-binary "execute-silent($CS --open {1})"
    sleep 1
    check "enter on a running session hides the picker" "$(picker_state)" '{"visible":false,"focused":false}'
    check "... and focuses the session's window" "$(tree | jq 'first(.. | select(.focused? == true) | .id)')" "$wcon"
    rm -f "$H/claude.log"
    "${W[@]}" "$CS" --open s2
    for _ in $(seq 50); do [[ -s $H/claude.log ]] && break; sleep 0.1; done
    check "enter on a stopped session resumes it in a new $term window" "$(cat "$H/claude.log" 2>/dev/null)" "$H/proj --resume s2"
    "${W[@]}" "$CS" --toggle
    sleep 0.5
    check "--toggle shows it again" "$(picker_state)" '{"visible":true,"focused":true}'
    # plain mode under sway: Enter on a running session focuses its window
    check "plain mode enter action on a running session" "$("${W[@]}" "$CS" --enter w1)" "execute-silent($CS --focus w1)"
    "${W[@]}" "$CS" --focus w1
    sleep 0.3
    check "... focuses the session's window" "$(tree | jq 'first(.. | select(.focused? == true) | .id)')" "$wcon"
    "${W[@]}" "$CS" --toggle  # shown but not focused: brings it back to focus
    sleep 0.5
    "${W[@]}" "$CS" --toggle
    sleep 0.5
    check "--toggle on the focused picker hides it" "$(picker_state)" '{"visible":false,"focused":false}'

    kill "$swaypid" "$(cat "$H/w.pid")" 2>/dev/null || true
    wait "$swaypid" 2>/dev/null || true
    rm -f "$C/projects/-p/w1.jsonl" "$C/sessions/$(cat "$H/w.pid").json" "$R/claude-sessions.sock"
}
for term in alacritty foot; do
    if command -v sway >/dev/null && command -v "$term" >/dev/null; then window_mode "$term"; else echo "sway window mode ($term): skipped, not installed"; fi
done

exit $fail
