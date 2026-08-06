#!/usr/bin/env zsh

setopt pipefail
unsetopt bg_nice

# Installer markers (kept in sync with uninstall.sh) so fixtures can embed them.
POWERLENS_MARKER_START="# >>> PowerLens installer >>>"
POWERLENS_MARKER_END="# <<< PowerLens installer <<<"

PASS=0
FAIL=0

assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        (( ++PASS )); print "  PASS: $desc"
    else
        (( ++FAIL )); print -u2 "  FAIL: $desc — got '$got', want '$want'"
    fi
}

assert_absent() {
    local path=$1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        (( ++PASS )); print "  PASS: path absent: $path"
    else
        (( ++FAIL )); print -u2 "  FAIL: expected path to be absent: $path"
    fi
}

assert_file() {
    local file_path=$1
    if [[ -e "$file_path" ]]; then
        (( ++PASS )); print "  PASS: file exists: $file_path"
    else
        (( ++FAIL )); print -u2 "  FAIL: expected file: $file_path"
    fi
}

assert_true() {
    local desc=$1 condition=$2
    if eval "$condition"; then
        (( ++PASS )); print "  PASS: $desc"
    else
        (( ++FAIL )); print -u2 "  FAIL: $desc"
    fi
}

assert_contains() {
    local file_path=$1 expected=$2
    if grep -F -q -- "$expected" "$file_path" 2>/dev/null; then
        (( ++PASS )); print "  PASS: $file_path contains expected text"
    else
        (( ++FAIL )); print -u2 "  FAIL: $file_path missing '$expected'"
    fi
}

assert_missing() {
    local file_path=$1 unexpected=$2
    if ! grep -F -q -- "$unexpected" "$file_path" 2>/dev/null; then
        (( ++PASS )); print "  PASS: $file_path lacks '$unexpected'"
    else
        (( ++FAIL )); print -u2 "  FAIL: $file_path still contains '$unexpected'"
    fi
}

make_test_uname() {
    local bin_dir=$1 system_name=$2 architecture=$3
    mkdir -p -- "$bin_dir"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'case "$1" in'
        print -r -- "    -s) print -r -- ${(qqq)system_name} ;;"
        print -r -- "    -m) print -r -- ${(qqq)architecture} ;;"
        print -r -- '    *) command /usr/bin/uname "$@" ;;'
        print -r -- 'esac'
    } > "$bin_dir/uname"
    chmod +x "$bin_dir/uname"
}

PROJECT_ROOT=${0:A:h:h}
case_dir=$(mktemp -d)
trap 'rm -rf -- "$case_dir"' EXIT

# run_uninstaller HOME INSTALL_DIR ERRFILE [OUTFILE]
run_uninstaller() {
    local home_dir=$1 install_dir=$2 error_file=$3 output_file=${4:-}
    mkdir -p -- "$home_dir"
    if [[ -n "$output_file" ]]; then
        env \
          HOME="$home_dir" \
          SHELL=/bin/zsh \
          POWERLENS_ZSHRC="$home_dir/.zshrc" \
          POWERLENS_INSTALL_DIR="$install_dir" \
          XDG_CACHE_HOME="$home_dir/.cache" \
          zsh "$PROJECT_ROOT/uninstall.sh" >"$output_file" 2>"$error_file"
    else
        env \
          HOME="$home_dir" \
          SHELL=/bin/zsh \
          POWERLENS_ZSHRC="$home_dir/.zshrc" \
          POWERLENS_INSTALL_DIR="$install_dir" \
          XDG_CACHE_HOME="$home_dir/.cache" \
          zsh "$PROJECT_ROOT/uninstall.sh" 2>"$error_file"
    fi
}

print "\n=== Preconditions ==="

# macOS guard: Linux uname → non-zero exit
linux_uname_bin="$case_dir/linux-uname-bin"
make_test_uname "$linux_uname_bin" Linux arm64
linux_home="$case_dir/linux-home"
linux_error="$case_dir/linux-error"
mkdir -p -- "$linux_home"
env \
  PATH="$linux_uname_bin:$PATH" \
  HOME="$linux_home" \
  POWERLENS_ZSHRC="$linux_home/.zshrc" \
  POWERLENS_INSTALL_DIR="$linux_home/install" \
  XDG_CACHE_HOME="$linux_home/.cache" \
  zsh "$PROJECT_ROOT/uninstall.sh" 2>"$linux_error"
assert_true "non-macOS uninstall exits non-zero" "(( $? != 0 ))"
assert_contains "$linux_error" "requires macOS"

# Symlinked startup file → refused
symlink_home="$case_dir/symlink-home"
mkdir -p -- "$symlink_home"
: > "$symlink_home/.zshrc.real"
ln -s "$symlink_home/.zshrc.real" "$symlink_home/.zshrc"
symlink_error="$case_dir/symlink-error"
run_uninstaller "$symlink_home" "$symlink_home/install" "$symlink_error"
assert_true "symlinked startup file exits non-zero" "(( $? != 0 ))"
assert_contains "$symlink_error" "symbolic link"

print "\n=== Stop daemon ==="

daemon_home="$case_dir/daemon-home"
daemon_cache="$daemon_home/.cache/powerlens"
mkdir -p -- "$daemon_cache"
: > "$daemon_home/.zshrc"

# Fake daemon: a sleep renamed via exec -a so pkill -f matches "powerlens-fetch".
fake_daemon_bin="$case_dir/powerlens-fetch-fake"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'exec -a powerlens-fetch sleep 60'
} > "$fake_daemon_bin"
chmod +x "$fake_daemon_bin"
"$fake_daemon_bin" &!
fake_pid=$!
print -r -- "$fake_pid" > "$daemon_cache/daemon.pid"

# Give the exec a moment to re-label the process.
sleep 0.3

daemon_error="$case_dir/daemon-error"
run_uninstaller "$daemon_home" "$daemon_home/install" "$daemon_error"
assert_eq "daemon uninstall exits zero" "$?" "0"
sleep 0.3
assert_true "daemon process stopped" "! kill -0 $fake_pid 2>/dev/null"

print "\n=== Clean .zshrc marker block ==="

zshrc_home="$case_dir/zshrc-home"
mkdir -p -- "$zshrc_home"
{
    print -r -- '# user content before'
    print -r -- 'export EDITOR=vim'
    print -r -- 'POWERLENS_MODE=compact'
    print -r -- ''
    print -r -- "$POWERLENS_MARKER_START"
    print -r -- 'source "/some/install/powerlens.plugin.zsh"'
    print -r -- "$POWERLENS_MARKER_END"
    print -r -- '# user content after'
} > "$zshrc_home/.zshrc"

zshrc_error="$case_dir/zshrc-error"
run_uninstaller "$zshrc_home" "$zshrc_home/install" "$zshrc_error"
assert_eq "zshrc clean exits zero" "$?" "0"
assert_missing "$zshrc_home/.zshrc" "$POWERLENS_MARKER_START"
assert_missing "$zshrc_home/.zshrc" "source \"/some/install/powerlens.plugin.zsh\""
assert_contains "$zshrc_home/.zshrc" '# user content before'
assert_contains "$zshrc_home/.zshrc" '# user content after'
assert_contains "$zshrc_home/.zshrc" 'POWERLENS_MODE=compact'
# A backup was made.
assert_true "zshrc backup created" \
  '[[ -n "$(print -rl -- "$zshrc_home"/.zshrc.powerlens-backup-*(N))" ]]'

print "\n=== Manual (unmarked) install left untouched ==="

manual_home="$case_dir/manual-home"
mkdir -p -- "$manual_home"
{
    print -r -- 'plugins=(git powerlens)'
} > "$manual_home/.zshrc"
manual_error="$case_dir/manual-error"
run_uninstaller "$manual_home" "$manual_home/install" "$manual_error"
assert_eq "manual install uninstall exits zero" "$?" "0"
assert_contains "$manual_home/.zshrc" 'plugins=(git powerlens)'
assert_contains "$manual_error" "powerlens"

print "\n=== Remove install and cache directories ==="

full_home="$case_dir/full-home"
full_install="$full_home/install/powerlens"
full_cache="$full_home/.cache/powerlens"
mkdir -p -- "$full_install" "$full_cache"
: > "$full_install/powerlens.plugin.zsh"
: > "$full_install/powerlens.zsh"
: > "$full_cache/metrics.json"
: > "$full_home/.zshrc"

full_error="$case_dir/full-error"
run_uninstaller "$full_home" "$full_install" "$full_error"
assert_eq "full uninstall exits zero" "$?" "0"
assert_absent "$full_install"
assert_absent "$full_cache"

print "\n=== Wrong install dir guarded ==="

guard_home="$case_dir/guard-home"
guard_install="$guard_home/not-powerlens"
mkdir -p -- "$guard_install"
: > "$guard_install/important.txt"   # no powerlens.plugin.zsh
: > "$guard_home/.zshrc"
guard_error="$case_dir/guard-error"
run_uninstaller "$guard_home" "$guard_install" "$guard_error"
assert_eq "guarded uninstall exits zero" "$?" "0"
assert_file "$guard_install/important.txt"
assert_contains "$guard_error" "$guard_install"

print "\n=== Idempotency on clean HOME ==="

clean_home="$case_dir/clean-home"
mkdir -p -- "$clean_home"
: > "$clean_home/.zshrc"
clean_error="$case_dir/clean-error"
clean_output="$case_dir/clean-output"
run_uninstaller "$clean_home" "$clean_home/install" "$clean_error" "$clean_output"
assert_eq "clean-home uninstall exits zero" "$?" "0"
assert_file "$clean_home/.zshrc"
assert_true "no backup made on clean home" \
  '[[ -z "$(print -rl -- "$clean_home"/.zshrc.powerlens-backup-*(N))" ]]'
assert_contains "$clean_output" "exec zsh"

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
