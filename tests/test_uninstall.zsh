#!/usr/bin/env zsh

setopt pipefail
unsetopt bg_nice

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

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
