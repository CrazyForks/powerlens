#!/usr/bin/env zsh

setopt pipefail
unsetopt bg_nice

PASS=0
FAIL=0

assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        (( ++PASS ))
        print "  PASS: $desc"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: $desc — got '$got', want '$want'"
    fi
}

assert_file() {
    local file_path=$1
    if [[ -e "$file_path" ]]; then
        (( ++PASS ))
        print "  PASS: file exists: $file_path"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: expected file: $file_path"
    fi
}

assert_dir() {
    local directory_path=$1
    if [[ -d "$directory_path" ]]; then
        (( ++PASS ))
        print "  PASS: directory exists: $directory_path"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: expected directory: $directory_path"
    fi
}

assert_absent() {
    local path=$1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        (( ++PASS ))
        print "  PASS: path absent: $path"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: expected path to be absent: $path"
    fi
}

assert_true() {
    local desc=$1 condition=$2
    if eval "$condition"; then
        (( ++PASS ))
        print "  PASS: $desc"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: $desc"
    fi
}

assert_contains() {
    local file_path=$1 expected=$2
    if grep -F -q -- "$expected" "$file_path" 2>/dev/null; then
        (( ++PASS ))
        print "  PASS: $file_path contains expected text"
    else
        (( ++FAIL ))
        print -u2 "  FAIL: $file_path does not contain '$expected'"
    fi
}

count_fixed() {
    local file_path=$1 text=$2
    grep -F -c -- "$text" "$file_path" 2>/dev/null || true
}

count_backups() {
    local home_dir=$1
    local -a backups
    backups=("$home_dir"/.zshrc.powerlens-backup-*(N))
    print ${#backups}
}

line_number() {
    local file_path=$1 text=$2
    grep -n -F -- "$text" "$file_path" 2>/dev/null | head -n 1 | cut -d: -f1
}

directory_snapshot() {
    find "$1" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort
}

count_install_temps() {
    local parent_dir=$1
    local -a temporary_dirs

    temporary_dirs=("$parent_dir"/.powerlens-install-*(N))
    print ${#temporary_dirs}
}

count_install_temps_recursively() {
    local parent_dir=$1

    find "$parent_dir" -type d -name '.powerlens-install-*' -print 2>/dev/null \
      | wc -l | tr -d '[:space:]'
}

count_nested_git_repositories() {
    local install_dir=$1

    find "$install_dir" -mindepth 2 -type d -name .git -print 2>/dev/null \
      | wc -l | tr -d '[:space:]'
}

wait_for_either_file() {
    local first_file=$1 second_file=$2
    local attempt

    for attempt in {1..200}; do
        [[ -e "$first_file" || -e "$second_file" ]] && return 0
        sleep 0.02
    done
    return 1
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

run_without_controlling_tty() {
    /usr/bin/python3 -c '
import os
import sys

child = os.fork()
if child:
    _, status = os.waitpid(child, 0)
    os._exit(os.waitstatus_to_exitcode(status))

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@"
}

run_installer() {
    local home_dir=$1 install_dir=$2 repo_url=$3 error_file=$4
    local output_file=${5:-}

    mkdir -p -- "$home_dir"
    if [[ -n "$output_file" ]]; then
        env \
          HOME="$home_dir" \
          SHELL=/bin/zsh \
          POWERLENS_SHELL_MODE=zsh \
          POWERLENS_ZSHRC="$home_dir/.zshrc" \
          POWERLENS_REPO_URL="$repo_url" \
          POWERLENS_INSTALL_DIR="$install_dir" \
          zsh "$PROJECT_ROOT/install.sh" >"$output_file" 2>"$error_file"
    else
        env \
          HOME="$home_dir" \
          SHELL=/bin/zsh \
          POWERLENS_SHELL_MODE=zsh \
          POWERLENS_ZSHRC="$home_dir/.zshrc" \
          POWERLENS_REPO_URL="$repo_url" \
          POWERLENS_INSTALL_DIR="$install_dir" \
          zsh "$PROJECT_ROOT/install.sh" 2>"$error_file"
    fi
}

PROJECT_ROOT=${0:A:h:h}
case_dir=$(mktemp -d)
trap 'rm -rf -- "$case_dir"' EXIT

origin="$case_dir/origin.git"
mkdir -p "$origin/bin"
git -C "$origin" init --initial-branch=main >/dev/null
git -C "$origin" config user.email test@example.com
git -C "$origin" config user.name 'PowerLens test'
print 'POWERLENS_FIXTURE_LOADED=1' > "$origin/powerlens.plugin.zsh"
print '# fixture implementation' > "$origin/powerlens.zsh"
print '#!/usr/bin/env zsh\nexit 0' > "$origin/bin/powerlens-fetch-arm64"
print '#!/usr/bin/env zsh\nexit 0' > "$origin/bin/powerlens-fetch-amd64"
chmod +x "$origin/bin/powerlens-fetch-arm64" "$origin/bin/powerlens-fetch-amd64"
git -C "$origin" add powerlens.plugin.zsh powerlens.zsh bin
git -C "$origin" commit -m fixture >/dev/null

print "\n=== Installer preconditions and cleanup ==="
linux_uname_bin="$case_dir/linux-uname-bin"
make_test_uname "$linux_uname_bin" Linux arm64
linux_home="$case_dir/linux-home"
linux_error="$case_dir/linux-error"
mkdir -p -- "$linux_home"
env \
  PATH="$linux_uname_bin:$PATH" \
  HOME="$linux_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$linux_home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$linux_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$linux_error"
linux_status=$?

assert_true "non-macOS install exits non-zero" '(( linux_status != 0 ))'
assert_contains "$linux_error" "macOS"
assert_absent "$linux_home/install"

invalid_mode_home="$case_dir/invalid-mode-home"
invalid_mode_error="$case_dir/invalid-mode-error"
mkdir -p -- "$invalid_mode_home"
env \
  HOME="$invalid_mode_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=fish \
  POWERLENS_ZSHRC="$invalid_mode_home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$invalid_mode_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$invalid_mode_error"
invalid_mode_status=$?

assert_true "invalid shell mode exits non-zero" '(( invalid_mode_status != 0 ))'
assert_contains "$invalid_mode_error" "POWERLENS_SHELL_MODE must be omz or zsh"
assert_absent "$invalid_mode_home/install"

non_regular_home="$case_dir/non-regular-home"
non_regular_zshrc="$non_regular_home/.zshrc"
non_regular_error="$case_dir/non-regular-error"
mkdir -p -- "$non_regular_zshrc"
env \
  HOME="$non_regular_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$non_regular_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$non_regular_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$non_regular_error"
non_regular_status=$?

assert_true "non-regular startup path exits non-zero" \
  '(( non_regular_status != 0 ))'
assert_contains "$non_regular_error" "startup file must be a writable regular file"
assert_absent "$non_regular_home/install"

plain_symlink_home="$case_dir/plain-symlink-home"
plain_symlink_target="$case_dir/plain-symlink-target"
plain_symlink_zshrc="$plain_symlink_home/.zshrc"
plain_symlink_error="$case_dir/plain-symlink-error"
mkdir -p -- "$plain_symlink_home"
print 'plain symlink sentinel' > "$plain_symlink_target"
ln -s -- "$plain_symlink_target" "$plain_symlink_zshrc"
env \
  HOME="$plain_symlink_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$plain_symlink_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$plain_symlink_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$plain_symlink_error"
plain_symlink_status=$?

assert_true "plain-zsh startup symlink exits non-zero" \
  '(( plain_symlink_status != 0 ))'
assert_true "plain-zsh startup symlink remains a link" \
  '[[ -L "$plain_symlink_zshrc" ]]'
assert_eq "plain-zsh startup symlink target remains unchanged" \
  "$(<"$plain_symlink_target")" "plain symlink sentinel"
assert_absent "$plain_symlink_home/install"
assert_contains "$plain_symlink_error" "configure its target manually"

omz_symlink_home="$case_dir/omz-symlink-home"
omz_symlink_target="$case_dir/omz-symlink-target"
omz_symlink_zshrc="$omz_symlink_home/.zshrc"
omz_symlink_error="$case_dir/omz-symlink-error"
mkdir -p -- "$omz_symlink_home"
print 'plugins=(git)' > "$omz_symlink_target"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$omz_symlink_target"
omz_symlink_before=$(<"$omz_symlink_target")
ln -s -- "$omz_symlink_target" "$omz_symlink_zshrc"
env \
  HOME="$omz_symlink_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=omz \
  POWERLENS_ZSHRC="$omz_symlink_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$omz_symlink_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$omz_symlink_error"
omz_symlink_status=$?

assert_true "Oh My Zsh startup symlink exits non-zero" \
  '(( omz_symlink_status != 0 ))'
assert_true "Oh My Zsh startup symlink remains a link" \
  '[[ -L "$omz_symlink_zshrc" ]]'
assert_eq "Oh My Zsh startup symlink target remains unchanged" \
  "$(<"$omz_symlink_target")" "$omz_symlink_before"
assert_absent "$omz_symlink_home/install"
assert_contains "$omz_symlink_error" "configure its target manually"

ambiguous_mode_home="$case_dir/ambiguous-mode-home"
ambiguous_mode_error="$case_dir/ambiguous-mode-error"
mkdir -p -- "$ambiguous_mode_home"
no_tty_probe=$(run_without_controlling_tty zsh -fc \
  '[[ -r /dev/tty && -w /dev/tty ]] && print attached || print detached')
assert_eq "non-interactive ambiguity case has no controlling TTY" \
  "$no_tty_probe" "detached"
run_without_controlling_tty env -u POWERLENS_SHELL_MODE -u ZSH -u ZSH_CUSTOM \
  HOME="$ambiguous_mode_home" \
  SHELL=/bin/bash \
  POWERLENS_ZSHRC="$ambiguous_mode_home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$ambiguous_mode_home/install" \
  zsh "$PROJECT_ROOT/install.sh" </dev/null 2>"$ambiguous_mode_error"
ambiguous_mode_status=$?

assert_true "non-interactive ambiguous shell exits non-zero" \
  '(( ambiguous_mode_status != 0 ))'
assert_contains "$ambiguous_mode_error" \
  "set POWERLENS_SHELL_MODE=omz or POWERLENS_SHELL_MODE=zsh"
assert_absent "$ambiguous_mode_home/install"

missing_parent_home="$case_dir/missing-parent-home"
missing_parent_zshrc="$missing_parent_home/config/.zshrc"
missing_parent_error="$case_dir/missing-parent-error"
mkdir -p -- "$missing_parent_home"
env \
  HOME="$missing_parent_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$missing_parent_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$missing_parent_home/install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$missing_parent_error"
missing_parent_status=$?

assert_true "missing startup-file parent exits non-zero" \
  '(( missing_parent_status != 0 ))'
assert_absent "$missing_parent_home/config"
assert_absent "$missing_parent_home/install"

readonly_parent_home="$case_dir/readonly-parent-home"
readonly_parent_dir="$readonly_parent_home/config"
readonly_parent_zshrc="$readonly_parent_dir/.zshrc"
readonly_parent_install="$case_dir/readonly-parent-install"
readonly_parent_error="$case_dir/readonly-parent-error"
mkdir -p -- "$readonly_parent_dir"
print 'readonly parent sentinel' > "$readonly_parent_zshrc"
readonly_parent_before=$(<"$readonly_parent_zshrc")
chmod 500 "$readonly_parent_dir"
assert_true "read-only startup parent fixture is not writable" \
  '[[ ! -w "$readonly_parent_dir" ]]'
env \
  HOME="$readonly_parent_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$readonly_parent_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$readonly_parent_install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$readonly_parent_error"
readonly_parent_status=$?
chmod 700 "$readonly_parent_dir"

assert_true "existing startup file with read-only parent exits non-zero" \
  '(( readonly_parent_status != 0 ))'
assert_eq "read-only parent failure preserves startup file" \
  "$(<"$readonly_parent_zshrc")" "$readonly_parent_before"
assert_absent "$readonly_parent_install"
assert_contains "$readonly_parent_error" "startup file parent"

noexecute_parent_home="$case_dir/noexecute-parent-home"
noexecute_parent_dir="$noexecute_parent_home/config"
noexecute_parent_zshrc="$noexecute_parent_dir/.zshrc"
noexecute_parent_install="$case_dir/noexecute-parent-install"
noexecute_parent_error="$case_dir/noexecute-parent-error"
mkdir -p -- "$noexecute_parent_dir"
print 'no-execute parent sentinel' > "$noexecute_parent_zshrc"
noexecute_parent_before=$(<"$noexecute_parent_zshrc")
chmod 200 "$noexecute_parent_dir"
assert_true "mode 0200 startup parent is writable but not searchable" \
  '[[ -w "$noexecute_parent_dir" && ! -x "$noexecute_parent_dir" ]]'
env \
  HOME="$noexecute_parent_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$noexecute_parent_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$noexecute_parent_install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$noexecute_parent_error"
noexecute_parent_status=$?
chmod 700 "$noexecute_parent_dir"

assert_true "existing startup file with unsearchable parent exits non-zero" \
  '(( noexecute_parent_status != 0 ))'
assert_eq "unsearchable parent failure preserves startup file" \
  "$(<"$noexecute_parent_zshrc")" "$noexecute_parent_before"
assert_absent "$noexecute_parent_install"
assert_contains "$noexecute_parent_error" \
  "startup file parent must exist and be writable and searchable"

zdotdir_home="$case_dir/zdotdir-home"
zdotdir="$case_dir/zdotdir"
zdotdir_install="$zdotdir_home/install"
mkdir -p -- "$zdotdir_home" "$zdotdir"
env \
  HOME="$zdotdir_home" \
  ZDOTDIR="$zdotdir" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$zdotdir_install" \
  zsh "$PROJECT_ROOT/install.sh"
zdotdir_status=$?

assert_eq "ZDOTDIR startup file install exits zero" "$zdotdir_status" "0"
assert_contains "$zdotdir/.zshrc" \
  "source \"$zdotdir_install/powerlens.plugin.zsh\""
assert_absent "$zdotdir_home/.zshrc"

opposite_source="$case_dir/opposite-source"
opposite_origin="$case_dir/opposite-origin.git"
git clone --quiet -- "$origin" "$opposite_source"
git -C "$opposite_source" rm -f -- bin/powerlens-fetch-arm64 >/dev/null
git -C "$opposite_source" commit -m missing-arm64 >/dev/null
git clone --quiet --bare "$opposite_source" "$opposite_origin"
architecture_uname_bin="$case_dir/architecture-uname-bin"
make_test_uname "$architecture_uname_bin" Darwin arm64
architecture_home="$case_dir/architecture-home"
architecture_parent="$architecture_home/installs"
architecture_error="$case_dir/architecture-error"
mkdir -p -- "$architecture_parent"
architecture_before=$(directory_snapshot "$architecture_parent")
env \
  PATH="$architecture_uname_bin:$PATH" \
  HOME="$architecture_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$architecture_home/.zshrc" \
  POWERLENS_REPO_URL="$opposite_origin" \
  POWERLENS_INSTALL_DIR="$architecture_parent/powerlens" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$architecture_error"
architecture_status=$?

assert_true "missing native-architecture binary exits non-zero" \
  '(( architecture_status != 0 ))'
assert_contains "$architecture_error" "missing executable bin/powerlens-fetch-arm64"
assert_eq "architecture validation leaves target parent unchanged" \
  "$(directory_snapshot "$architecture_parent")" "$architecture_before"
assert_eq "architecture validation leaves no install temporary directory" \
  "$(count_install_temps "$architecture_parent")" "0"

missing_plugin_source="$case_dir/missing-plugin-source"
missing_plugin_origin="$case_dir/missing-plugin-origin.git"
git clone --quiet -- "$origin" "$missing_plugin_source"
git -C "$missing_plugin_source" rm -f -- powerlens.plugin.zsh >/dev/null
git -C "$missing_plugin_source" commit -m missing-plugin >/dev/null
git clone --quiet --bare "$missing_plugin_source" "$missing_plugin_origin"
missing_plugin_home="$case_dir/missing-plugin-home"
missing_plugin_parent="$missing_plugin_home/installs"
missing_plugin_error="$case_dir/missing-plugin-error"
mkdir -p -- "$missing_plugin_parent"
env \
  HOME="$missing_plugin_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$missing_plugin_home/.zshrc" \
  POWERLENS_REPO_URL="$missing_plugin_origin" \
  POWERLENS_INSTALL_DIR="$missing_plugin_parent/powerlens" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$missing_plugin_error"
missing_plugin_status=$?

assert_true "missing plugin file exits non-zero" \
  '(( missing_plugin_status != 0 ))'
assert_contains "$missing_plugin_error" "missing powerlens.plugin.zsh"
assert_absent "$missing_plugin_parent/powerlens"
assert_eq "missing plugin validation leaves no install temporary directory" \
  "$(count_install_temps "$missing_plugin_parent")" "0"

clone_failure_home="$case_dir/clone-failure-home"
clone_failure_parent="$clone_failure_home/installs"
clone_failure_error="$case_dir/clone-failure-error"
mkdir -p -- "$clone_failure_parent"
clone_failure_before=$(directory_snapshot "$clone_failure_parent")
env \
  HOME="$clone_failure_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$clone_failure_home/.zshrc" \
  POWERLENS_REPO_URL="$case_dir/no-such-origin.git" \
  POWERLENS_INSTALL_DIR="$clone_failure_parent/powerlens" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$clone_failure_error"
clone_failure_status=$?

assert_true "clone failure exits non-zero" '(( clone_failure_status != 0 ))'
assert_absent "$clone_failure_parent/powerlens"
assert_eq "clone failure leaves target parent unchanged" \
  "$(directory_snapshot "$clone_failure_parent")" "$clone_failure_before"
assert_eq "clone failure leaves no install temporary directory" \
  "$(count_install_temps "$clone_failure_parent")" "0"

term_home="$case_dir/term-home"
term_parent="$term_home/installs"
term_install="$term_parent/powerlens"
term_bin="$case_dir/term-bin"
term_marker="$case_dir/term-marker"
term_error="$case_dir/term-error"
mkdir -p -- "$term_parent" "$term_bin"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'if [[ "$1" == clone ]]; then'
    print -r -- '    command /usr/bin/git "$@"'
    print -r -- '    clone_status=$?'
    print -r -- '    kill -TERM "$PPID"'
    print -r -- '    exit "$clone_status"'
    print -r -- 'fi'
    print -r -- 'exec /usr/bin/git "$@"'
} > "$term_bin/git"
chmod +x "$term_bin/git"
env \
  PATH="$term_bin:$PATH" \
  HOME="$term_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$term_home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$term_install" \
  zsh -c 'source "$1"; print -r -- reached > "$2"' \
  powerlens-term "$PROJECT_ROOT/install.sh" "$term_marker" \
  >/dev/null 2>"$term_error"
term_status=$?

assert_eq "TERM exits with the conventional signal status" "$term_status" "143"
assert_absent "$term_marker"
assert_absent "$term_install"
assert_eq "TERM cleans the install temporary directory" \
  "$(count_install_temps "$term_parent")" "0"

print "\n=== Concurrent first-install publication ==="
race_home="$case_dir/race-home"
race_parent="$case_dir/race-parent"
race_install="$race_parent/powerlens"
race_zshrc="$race_home/.zshrc"
race_bin="$case_dir/race-bin"
race_control="$case_dir/race-control"
race_lock="${race_install}.powerlens-install-lock"
mkdir -p -- "$race_home" "$race_parent" "$race_bin" "$race_control"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'command /usr/bin/git "$@"'
    print -r -- 'git_status=$?'
    print -r -- 'if [[ "$1" == clone && "$git_status" == 0 ]]; then'
    print -r -- '    : > "$POWERLENS_TEST_RACE_CONTROL/cloned-$POWERLENS_TEST_RACE_ID"'
    print -r -- '    integer attempt'
    print -r -- '    for attempt in {1..200}; do'
    print -r -- '        [[ -e "$POWERLENS_TEST_RACE_CONTROL/cloned-one" && -e "$POWERLENS_TEST_RACE_CONTROL/cloned-two" ]] && exit 0'
    print -r -- '        sleep 0.02'
    print -r -- '    done'
    print -r -- '    exit 70'
    print -r -- 'fi'
    print -r -- 'exit "$git_status"'
} > "$race_bin/git"
{
    print -r -- '#!/usr/bin/env zsh'
    print -r -- 'if [[ "${@: -1}" == "$POWERLENS_TEST_RACE_INSTALL_DIR" ]]; then'
    print -r -- '    : > "$POWERLENS_TEST_RACE_CONTROL/publishing-$POWERLENS_TEST_RACE_ID"'
    print -r -- '    integer attempt'
    print -r -- '    for attempt in {1..200}; do'
    print -r -- '        [[ -e "$POWERLENS_TEST_RACE_CONTROL/release-publisher" ]] && exec /bin/mv "$@"'
    print -r -- '        sleep 0.02'
    print -r -- '    done'
    print -r -- '    exit 71'
    print -r -- 'fi'
    print -r -- 'exec /bin/mv "$@"'
} > "$race_bin/mv"
chmod +x "$race_bin/git" "$race_bin/mv"

(
    env \
      PATH="$race_bin:$PATH" \
      HOME="$race_home" \
      SHELL=/bin/zsh \
      POWERLENS_SHELL_MODE=zsh \
      POWERLENS_ZSHRC="$race_zshrc" \
      POWERLENS_REPO_URL="$origin" \
      POWERLENS_INSTALL_DIR="$race_install" \
      POWERLENS_TEST_RACE_CONTROL="$race_control" \
      POWERLENS_TEST_RACE_ID=one \
      POWERLENS_TEST_RACE_INSTALL_DIR="$race_install" \
      zsh "$PROJECT_ROOT/install.sh" \
      >"$race_control/output-one" 2>"$race_control/error-one"
    print -r -- "$?" > "$race_control/status-one"
) &
race_pid_one=$!
(
    env \
      PATH="$race_bin:$PATH" \
      HOME="$race_home" \
      SHELL=/bin/zsh \
      POWERLENS_SHELL_MODE=zsh \
      POWERLENS_ZSHRC="$race_zshrc" \
      POWERLENS_REPO_URL="$origin" \
      POWERLENS_INSTALL_DIR="$race_install" \
      POWERLENS_TEST_RACE_CONTROL="$race_control" \
      POWERLENS_TEST_RACE_ID=two \
      POWERLENS_TEST_RACE_INSTALL_DIR="$race_install" \
      zsh "$PROJECT_ROOT/install.sh" \
      >"$race_control/output-two" 2>"$race_control/error-two"
    print -r -- "$?" > "$race_control/status-two"
) &
race_pid_two=$!

race_publisher_reached=no
wait_for_either_file "$race_control/publishing-one" \
  "$race_control/publishing-two" && race_publisher_reached=yes
race_loser_finished_before_release=no
wait_for_either_file "$race_control/status-one" \
  "$race_control/status-two" && race_loser_finished_before_release=yes
race_lock_owned_while_publishing=no
[[ -d "$race_lock" ]] && race_lock_owned_while_publishing=yes
: > "$race_control/release-publisher"
wait "$race_pid_one"
wait "$race_pid_two"
race_status_one=$(<"$race_control/status-one")
race_status_two=$(<"$race_control/status-two")
race_success_count=0
[[ "$race_status_one" == 0 ]] && (( ++race_success_count ))
[[ "$race_status_two" == 0 ]] && (( ++race_success_count ))

assert_eq "concurrent installers reach the deterministic publication point" \
  "$race_publisher_reached" "yes"
assert_eq "losing concurrent installer fails while publisher owns the lock" \
  "$race_loser_finished_before_release" "yes"
assert_eq "losing installer preserves the publisher's exact lock" \
  "$race_lock_owned_while_publishing" "yes"
assert_eq "exactly one concurrent first install succeeds" \
  "$race_success_count" "1"
assert_eq "concurrent first install leaves one valid Git worktree" \
  "$(git -C "$race_install" rev-parse --is-inside-work-tree 2>/dev/null)" \
  "true"
assert_eq "concurrent first install leaves no nested repository" \
  "$(count_nested_git_repositories "$race_install")" "0"
assert_eq "concurrent first install leaves no temporary repository" \
  "$(count_install_temps_recursively "$race_parent")" "0"
assert_absent "$race_lock"
assert_eq "concurrent first install configures PowerLens once" \
  "$(count_fixed "$race_zshrc" '# >>> PowerLens installer >>>')" "1"

manual_source_home="$case_dir/manual-source-home"
manual_source_install="$manual_source_home/install"
manual_source_zshrc="$manual_source_home/.zshrc"
mkdir -p -- "$manual_source_home"
print -r -- "source \"$manual_source_install/powerlens.plugin.zsh\"" > "$manual_source_zshrc"
env \
  HOME="$manual_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$manual_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$manual_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
manual_source_status=$?

assert_eq "manual source install exits zero" "$manual_source_status" "0"
assert_eq "equivalent manual source remains single" \
  "$(count_fixed "$manual_source_zshrc" "$manual_source_install/powerlens.plugin.zsh")" "1"

readme_source_home="$case_dir/readme-source-home"
readme_source_install="$readme_source_home/.local/share/powerlens"
readme_source_zshrc="$readme_source_home/.zshrc"
mkdir -p -- "$readme_source_home"
print -r -- \
  'source "${XDG_DATA_HOME:-$HOME/.local/share}/powerlens/powerlens.plugin.zsh"' \
  > "$readme_source_zshrc"
readme_source_before=$(<"$readme_source_zshrc")
env -u XDG_DATA_HOME \
  HOME="$readme_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$readme_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$readme_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
readme_source_status=$?

assert_eq "README manual source install exits zero" \
  "$readme_source_status" "0"
assert_eq "README manual source remains unchanged" \
  "$(<"$readme_source_zshrc")" "$readme_source_before"
assert_eq "README manual source creates no backup" \
  "$(count_backups "$readme_source_home")" "0"

home_dollar_source_home="$case_dir/home-dollar-source-home"
home_dollar_source_install="$home_dollar_source_home/.local/share/powerlens"
home_dollar_source_zshrc="$home_dollar_source_home/.zshrc"
mkdir -p -- "$home_dollar_source_home"
print -r -- \
  'source "$HOME/.local/share/powerlens/powerlens.plugin.zsh"' \
  > "$home_dollar_source_zshrc"
home_dollar_source_before=$(<"$home_dollar_source_zshrc")
env \
  HOME="$home_dollar_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$home_dollar_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$home_dollar_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
home_dollar_source_status=$?

assert_eq "HOME dollar source install exits zero" \
  "$home_dollar_source_status" "0"
assert_eq "HOME dollar source remains unchanged" \
  "$(<"$home_dollar_source_zshrc")" "$home_dollar_source_before"
assert_eq "HOME dollar source creates no backup" \
  "$(count_backups "$home_dollar_source_home")" "0"

home_braced_source_home="$case_dir/home-braced-source-home"
home_braced_source_install="$home_braced_source_home/.local/share/powerlens"
home_braced_source_zshrc="$home_braced_source_home/.zshrc"
mkdir -p -- "$home_braced_source_home"
print -r -- \
  'source "${HOME}/.local/share/powerlens/powerlens.plugin.zsh"' \
  > "$home_braced_source_zshrc"
home_braced_source_before=$(<"$home_braced_source_zshrc")
env \
  HOME="$home_braced_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$home_braced_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$home_braced_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
home_braced_source_status=$?

assert_eq "braced HOME source install exits zero" \
  "$home_braced_source_status" "0"
assert_eq "braced HOME source remains unchanged" \
  "$(<"$home_braced_source_zshrc")" "$home_braced_source_before"
assert_eq "braced HOME source creates no backup" \
  "$(count_backups "$home_braced_source_home")" "0"

home_tilde_source_home="$case_dir/home-tilde-source-home"
home_tilde_source_install="$home_tilde_source_home/.local/share/powerlens"
home_tilde_source_zshrc="$home_tilde_source_home/.zshrc"
mkdir -p -- "$home_tilde_source_home"
print -r -- \
  'source ~/.local/share/powerlens/powerlens.plugin.zsh' \
  > "$home_tilde_source_zshrc"
home_tilde_source_before=$(<"$home_tilde_source_zshrc")
env \
  HOME="$home_tilde_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$home_tilde_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$home_tilde_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
home_tilde_source_status=$?

assert_eq "HOME tilde source install exits zero" \
  "$home_tilde_source_status" "0"
assert_eq "HOME tilde source remains unchanged" \
  "$(<"$home_tilde_source_zshrc")" "$home_tilde_source_before"
assert_eq "HOME tilde source creates no backup" \
  "$(count_backups "$home_tilde_source_home")" "0"

xdg_dollar_source_home="$case_dir/xdg-dollar-source-home"
xdg_dollar_data_home="$case_dir/xdg-dollar-data"
xdg_dollar_source_install="$xdg_dollar_data_home/powerlens"
xdg_dollar_source_zshrc="$xdg_dollar_source_home/.zshrc"
mkdir -p -- "$xdg_dollar_source_home" "$xdg_dollar_data_home"
print -r -- \
  'source "$XDG_DATA_HOME/powerlens/powerlens.plugin.zsh"' \
  > "$xdg_dollar_source_zshrc"
xdg_dollar_source_before=$(<"$xdg_dollar_source_zshrc")
env \
  HOME="$xdg_dollar_source_home" \
  XDG_DATA_HOME="$xdg_dollar_data_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$xdg_dollar_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$xdg_dollar_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
xdg_dollar_source_status=$?

assert_eq "XDG_DATA_HOME dollar source install exits zero" \
  "$xdg_dollar_source_status" "0"
assert_eq "XDG_DATA_HOME dollar source remains unchanged" \
  "$(<"$xdg_dollar_source_zshrc")" "$xdg_dollar_source_before"
assert_eq "XDG_DATA_HOME dollar source creates no backup" \
  "$(count_backups "$xdg_dollar_source_home")" "0"

xdg_braced_source_home="$case_dir/xdg-braced-source-home"
xdg_braced_data_home="$case_dir/xdg-braced-data"
xdg_braced_source_install="$xdg_braced_data_home/powerlens"
xdg_braced_source_zshrc="$xdg_braced_source_home/.zshrc"
mkdir -p -- "$xdg_braced_source_home" "$xdg_braced_data_home"
print -r -- \
  'source "${XDG_DATA_HOME}/powerlens/powerlens.plugin.zsh"' \
  > "$xdg_braced_source_zshrc"
xdg_braced_source_before=$(<"$xdg_braced_source_zshrc")
env \
  HOME="$xdg_braced_source_home" \
  XDG_DATA_HOME="$xdg_braced_data_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$xdg_braced_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$xdg_braced_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
xdg_braced_source_status=$?

assert_eq "braced XDG_DATA_HOME source install exits zero" \
  "$xdg_braced_source_status" "0"
assert_eq "braced XDG_DATA_HOME source remains unchanged" \
  "$(<"$xdg_braced_source_zshrc")" "$xdg_braced_source_before"
assert_eq "braced XDG_DATA_HOME source creates no backup" \
  "$(count_backups "$xdg_braced_source_home")" "0"

comment_source_home="$case_dir/comment-source-home"
comment_source_install="$comment_source_home/install"
comment_source_zshrc="$comment_source_home/.zshrc"
mkdir -p -- "$comment_source_home"
print -r -- "source /dev/null # $comment_source_install/powerlens.plugin.zsh" \
  > "$comment_source_zshrc"
env \
  HOME="$comment_source_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$comment_source_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$comment_source_install" \
  zsh "$PROJECT_ROOT/install.sh"
comment_source_status=$?

assert_eq "path mentioned only in a comment installs successfully" \
  "$comment_source_status" "0"
zsh -fc 'source "$1"; [[ "$POWERLENS_FIXTURE_LOADED" == 1 ]]' \
  powerlens-test "$comment_source_zshrc"
comment_source_load_status=$?
assert_eq "comment path does not suppress real plugin source" \
  "$comment_source_load_status" "0"

print "\n=== Plain zsh installation ==="
mkdir -p -- "$case_dir/home"
install_output="$case_dir/install-output"
env \
  HOME="$case_dir/home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$case_dir/home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$case_dir/install" \
  zsh "$PROJECT_ROOT/install.sh" >"$install_output"
install_status=$?

assert_eq "plain install exits zero" "$install_status" "0"
assert_contains "$install_output" "Installing PowerLens"
assert_contains "$install_output" "Shell mode: plain zsh"
assert_contains "$install_output" "Install directory: $case_dir/install"
assert_contains "$install_output" "Startup file: $case_dir/home/.zshrc"
assert_eq "successful install ends with activation command" \
  "$(tail -n 1 "$install_output")" "exec zsh"
assert_file "$case_dir/install/.git"
assert_contains "$case_dir/home/.zshrc" \
  "source \"$case_dir/install/powerlens.plugin.zsh\""
assert_eq "managed block occurs once" \
  "$(count_fixed "$case_dir/home/.zshrc" \
    '# >>> PowerLens installer >>>')" \
  "1"

env \
  HOME="$case_dir/home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$case_dir/home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$case_dir/install" \
  zsh "$PROJECT_ROOT/install.sh"
install_status=$?

assert_eq "second run exits zero" "$install_status" "0"
assert_eq "managed block remains single" \
  "$(count_fixed "$case_dir/home/.zshrc" \
    '# >>> PowerLens installer >>>')" \
  "1"
assert_eq "idempotent run creates no backup" \
  "$(count_backups "$case_dir/home")" \
  "1"

print "\n=== Safe existing-install updates ==="
git -C "$case_dir/install" config remote.origin.fetch \
  'refs/heads/main:refs/remotes/origin/not-main'
print 'update fixture' > "$origin/update-fixture"
git -C "$origin" add update-fixture
git -C "$origin" commit -m update-fixture >/dev/null

update_error="$case_dir/update-error"
update_output="$case_dir/update-output"
run_installer "$case_dir/home" "$case_dir/install" "${origin%.git}/" \
  "$update_error" "$update_output"
update_status=$?

assert_eq "update exits zero" "$update_status" "0"
assert_contains "$update_output" "Updating PowerLens"
assert_eq "successful update ends with activation command" \
  "$(tail -n 1 "$update_output")" "exec zsh"
assert_eq "update refreshes origin/main from remote main" \
  "$(git -C "$case_dir/install" rev-parse refs/remotes/origin/main)" \
  "$(git -C "$origin" rev-parse main)"
assert_eq "update fast-forwards to origin/main" \
  "$(git -C "$case_dir/install" rev-parse HEAD)" \
  "$(git -C "$origin" rev-parse main)"

modified_dir="$case_dir/modified-install"
git clone --quiet -- "$origin" "$modified_dir"
modified_head_before=$(git -C "$modified_dir" rev-parse HEAD)
print 'local modification' >> "$modified_dir/powerlens.zsh"
modified_contents_before=$(<"$modified_dir/powerlens.zsh")
modified_error="$case_dir/modified-error"
run_installer "$case_dir/modified-home" "$modified_dir" "$origin" "$modified_error"
modified_status=$?

assert_true "modified tracked file update exits non-zero" \
  '(( modified_status != 0 ))'
assert_eq "modified tracked file preserves HEAD" \
  "$(git -C "$modified_dir" rev-parse HEAD)" "$modified_head_before"
assert_eq "modified tracked file remains unchanged" \
  "$(<"$modified_dir/powerlens.zsh")" "$modified_contents_before"
assert_contains "$modified_error" "local changes"
assert_contains "$modified_error" "commit, revert, or move"

untracked_dir="$case_dir/untracked-install"
git clone --quiet -- "$origin" "$untracked_dir"
untracked_head_before=$(git -C "$untracked_dir" rev-parse HEAD)
print 'must survive' > "$untracked_dir/local-untracked"
untracked_error="$case_dir/untracked-error"
run_installer "$case_dir/untracked-home" "$untracked_dir" "$origin" "$untracked_error"
untracked_status=$?

assert_true "untracked file update exits non-zero" \
  '(( untracked_status != 0 ))'
assert_eq "untracked file preserves HEAD" \
  "$(git -C "$untracked_dir" rev-parse HEAD)" "$untracked_head_before"
assert_eq "untracked file remains unchanged" \
  "$(<"$untracked_dir/local-untracked")" "must survive"
assert_contains "$untracked_error" "local changes"

print 'ignored-conflict' >> "$origin/.gitignore"
git -C "$origin" add .gitignore
git -C "$origin" commit -m ignore-conflict-fixture >/dev/null
ignored_dir="$case_dir/ignored-install"
git clone --quiet -- "$origin" "$ignored_dir"
ignored_head_before=$(git -C "$ignored_dir" rev-parse HEAD)
ignored_remote_before=$(git -C "$ignored_dir" rev-parse refs/remotes/origin/main)
print 'ignored local sentinel' > "$ignored_dir/ignored-conflict"
print 'upstream tracked contents' > "$origin/ignored-conflict"
git -C "$origin" add -f ignored-conflict
git -C "$origin" commit -m upstream-ignored-conflict >/dev/null
ignored_error="$case_dir/ignored-error"
run_installer "$case_dir/ignored-home" "$ignored_dir" "$origin" "$ignored_error"
ignored_status=$?

assert_true "ignored untracked conflict update exits non-zero" \
  '(( ignored_status != 0 ))'
assert_eq "ignored untracked conflict preserves HEAD" \
  "$(git -C "$ignored_dir" rev-parse HEAD)" "$ignored_head_before"
assert_eq "ignored untracked conflict fails before fetch or merge" \
  "$(git -C "$ignored_dir" rev-parse refs/remotes/origin/main)" \
  "$ignored_remote_before"
assert_eq "ignored untracked conflict preserves local file" \
  "$(<"$ignored_dir/ignored-conflict")" "ignored local sentinel"
assert_contains "$ignored_error" "local changes"

ignored_tracked_dir="$case_dir/ignored-tracked-install"
git clone --quiet -- "$origin" "$ignored_tracked_dir"
ignored_tracked_error="$case_dir/ignored-tracked-error"
run_installer "$case_dir/ignored-tracked-home" "$ignored_tracked_dir" \
  "$origin" "$ignored_tracked_error"
ignored_tracked_status=$?

assert_eq "clean tracked file matching gitignore can update" \
  "$ignored_tracked_status" "0"
assert_eq "tracked ignored path retains upstream contents" \
  "$(<"$ignored_tracked_dir/ignored-conflict")" "upstream tracked contents"

nongit_dir="$case_dir/nongit-install"
mkdir -p "$nongit_dir"
print 'do not replace' > "$nongit_dir/keep"
nongit_error="$case_dir/nongit-error"
run_installer "$case_dir/nongit-home" "$nongit_dir" "$origin" "$nongit_error"
nongit_status=$?

assert_true "non-Git target update exits non-zero" \
  '(( nongit_status != 0 ))'
assert_eq "non-Git target remains unchanged" \
  "$(<"$nongit_dir/keep")" "do not replace"
assert_contains "$nongit_error" "not a PowerLens Git repository"
assert_contains "$nongit_error" "move it aside or set POWERLENS_INSTALL_DIR"

unexpected_origin_dir="$case_dir/unexpected-origin-install"
git clone --quiet -- "$origin" "$unexpected_origin_dir"
unexpected_origin_head_before=$(git -C "$unexpected_origin_dir" rev-parse HEAD)
alternate_origin="$case_dir/alternate-origin"
git clone --quiet --bare "$origin" "$alternate_origin"
unexpected_origin_error="$case_dir/unexpected-origin-error"
run_installer "$case_dir/unexpected-origin-home" "$unexpected_origin_dir" \
  "$alternate_origin" "$unexpected_origin_error"
unexpected_origin_status=$?

assert_true "unexpected origin update exits non-zero" \
  '(( unexpected_origin_status != 0 ))'
assert_eq "unexpected origin preserves HEAD" \
  "$(git -C "$unexpected_origin_dir" rev-parse HEAD)" "$unexpected_origin_head_before"
assert_contains "$unexpected_origin_error" "unexpected origin"
assert_contains "$unexpected_origin_error" \
  "move it aside or set POWERLENS_INSTALL_DIR"

diverged_dir="$case_dir/diverged-install"
git clone --quiet -- "$origin" "$diverged_dir"
git -C "$diverged_dir" config user.email test@example.com
git -C "$diverged_dir" config user.name 'PowerLens test'
print 'local commit' > "$diverged_dir/local-commit"
git -C "$diverged_dir" add local-commit
git -C "$diverged_dir" commit -m local-commit >/dev/null
diverged_head_before=$(git -C "$diverged_dir" rev-parse HEAD)
diverged_error="$case_dir/diverged-error"
run_installer "$case_dir/diverged-home" "$diverged_dir" "$origin" "$diverged_error"
diverged_status=$?

assert_true "non-ancestor local commit update exits non-zero" \
  '(( diverged_status != 0 ))'
assert_eq "non-ancestor local commit preserves HEAD" \
  "$(git -C "$diverged_dir" rev-parse HEAD)" "$diverged_head_before"
assert_file "$diverged_dir/local-commit"
assert_contains "$diverged_error" "cannot fast-forward"
assert_contains "$diverged_error" "move it aside or set POWERLENS_INSTALL_DIR"

print "\n=== Installation path with spaces ==="
space_home="$case_dir/home with spaces"
space_install_dir="$case_dir/install with spaces"
mkdir -p -- "$space_home"
env \
  HOME="$space_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$space_home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$space_install_dir" \
  zsh "$PROJECT_ROOT/install.sh"
space_install_status=$?

assert_eq "space path install exits zero" "$space_install_status" "0"
zsh -fc 'source "$1"; [[ "$POWERLENS_FIXTURE_LOADED" == 1 ]]' \
  powerlens-test "$space_home/.zshrc"
space_source_status=$?
assert_eq "space path startup file sources plugin" "$space_source_status" "0"

print "\n=== Oh My Zsh installation ==="
omz_home="$case_dir/omz-home"
omz_zshrc="$omz_home/.zshrc"
mkdir -p "$omz_home"
print 'export ZSH="$HOME/.oh-my-zsh"' > "$omz_zshrc"
print 'plugins=(' >> "$omz_zshrc"
print '  git' >> "$omz_zshrc"
print ')' >> "$omz_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$omz_zshrc"

env \
  HOME="$omz_home" \
  SHELL=/bin/zsh \
  ZSH_CUSTOM="$case_dir/custom" \
  POWERLENS_ZSHRC="$omz_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  zsh "$PROJECT_ROOT/install.sh"
omz_install_status=$?

assert_eq "Oh My Zsh install exits zero" "$omz_install_status" "0"
assert_dir "$case_dir/custom/plugins/powerlens/.git"
loader_line=$(line_number "$omz_zshrc" 'source "$ZSH/oh-my-zsh.sh"')
powerlens_line=$(line_number "$omz_zshrc" 'plugins+=(powerlens)')
assert_true "PowerLens is configured before Oh My Zsh loads" \
  '(( powerlens_line < loader_line ))'

exact_loader_home="$case_dir/exact-loader-home"
exact_loader_zshrc="$exact_loader_home/.zshrc"
exact_loader_install="$case_dir/exact-loader-install"
mkdir -p "$exact_loader_home"
print 'plugins=(git)' > "$exact_loader_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$exact_loader_zshrc"
run_without_controlling_tty \
  env -u POWERLENS_SHELL_MODE -u ZSH -u ZSH_CUSTOM -u XDG_DATA_HOME \
  HOME="$exact_loader_home" \
  SHELL=/bin/bash \
  POWERLENS_ZSHRC="$exact_loader_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$exact_loader_install" \
  zsh "$PROJECT_ROOT/install.sh" </dev/null
exact_loader_status=$?

assert_eq "exact Oh My Zsh loader is automatic framework evidence" \
  "$exact_loader_status" "0"
assert_eq "exact Oh My Zsh loader receives one plugin entry" \
  "$(count_fixed "$exact_loader_zshrc" 'plugins+=(powerlens)')" "1"

lookalike_loader_home="$case_dir/lookalike-loader-home"
lookalike_loader_zshrc="$lookalike_loader_home/.zshrc"
lookalike_loader_install="$case_dir/lookalike-loader-install"
lookalike_loader_error="$case_dir/lookalike-loader-error"
mkdir -p "$lookalike_loader_home"
print 'plugins=(git)' > "$lookalike_loader_zshrc"
print 'source "$ZSH/oh-my-zsh.sh.disabled"' >> "$lookalike_loader_zshrc"
lookalike_loader_before=$(<"$lookalike_loader_zshrc")
env -u ZSH -u ZSH_CUSTOM -u XDG_DATA_HOME \
  HOME="$lookalike_loader_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=omz \
  POWERLENS_ZSHRC="$lookalike_loader_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$lookalike_loader_install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$lookalike_loader_error"
lookalike_loader_status=$?

assert_true "Oh My Zsh loader suffix lookalike exits non-zero" \
  '(( lookalike_loader_status != 0 ))'
assert_eq "loader suffix lookalike leaves startup file unchanged" \
  "$(<"$lookalike_loader_zshrc")" "$lookalike_loader_before"
assert_eq "loader suffix lookalike creates no backup" \
  "$(count_backups "$lookalike_loader_home")" "0"
assert_contains "$lookalike_loader_error" \
  "expected exactly one active Oh My Zsh loader"

detected_multiple_home="$case_dir/detected-multiple-home"
detected_multiple_zshrc="$detected_multiple_home/.zshrc"
detected_multiple_install="$case_dir/detected-multiple-install"
detected_multiple_error="$case_dir/detected-multiple-error"
mkdir -p "$detected_multiple_home"
print 'plugins=(git)' > "$detected_multiple_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$detected_multiple_zshrc"
print '. "${ZSH}/oh-my-zsh.sh"' >> "$detected_multiple_zshrc"
detected_multiple_before=$(<"$detected_multiple_zshrc")
env -u POWERLENS_SHELL_MODE -u ZSH -u ZSH_CUSTOM -u XDG_DATA_HOME \
  HOME="$detected_multiple_home" \
  SHELL=/bin/zsh \
  POWERLENS_ZSHRC="$detected_multiple_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$detected_multiple_install" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$detected_multiple_error"
detected_multiple_status=$?

assert_true "multiple exact loaders are detected as ambiguous Oh My Zsh" \
  '(( detected_multiple_status != 0 ))'
assert_eq "automatic multiple-loader failure preserves startup file" \
  "$(<"$detected_multiple_zshrc")" "$detected_multiple_before"
assert_eq "automatic multiple-loader failure creates no backup" \
  "$(count_backups "$detected_multiple_home")" "0"
assert_contains "$detected_multiple_error" \
  "expected exactly one active Oh My Zsh loader"

print "\n=== Existing Oh My Zsh plugin assignment ==="
existing_assignment_home="$case_dir/existing-assignment-home"
existing_assignment_zshrc="$existing_assignment_home/.zshrc"
mkdir -p "$existing_assignment_home"
print 'export ZSH="$HOME/.oh-my-zsh"' > "$existing_assignment_zshrc"
print 'plugins=(git powerlens)' >> "$existing_assignment_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$existing_assignment_zshrc"
existing_assignment_before=$(<"$existing_assignment_zshrc")

env \
  HOME="$existing_assignment_home" \
  SHELL=/bin/zsh \
  ZSH_CUSTOM="$case_dir/existing-assignment-custom" \
  POWERLENS_ZSHRC="$existing_assignment_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  zsh "$PROJECT_ROOT/install.sh"
existing_assignment_status=$?

assert_eq "existing plugins assignment exits zero" "$existing_assignment_status" "0"
assert_eq "existing plugins assignment remains unchanged" \
  "$(<"$existing_assignment_zshrc")" "$existing_assignment_before"
assert_eq "existing plugins assignment creates no backup" \
  "$(count_backups "$existing_assignment_home")" "0"

print "\n=== Existing Oh My Zsh append assignment ==="
existing_append_home="$case_dir/existing-append-home"
existing_append_zshrc="$existing_append_home/.zshrc"
mkdir -p "$existing_append_home"
print 'export ZSH="$HOME/.oh-my-zsh"' > "$existing_append_zshrc"
print 'plugins+=(powerlens)' >> "$existing_append_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$existing_append_zshrc"
existing_append_before=$(<"$existing_append_zshrc")

env \
  HOME="$existing_append_home" \
  SHELL=/bin/zsh \
  ZSH_CUSTOM="$case_dir/existing-append-custom" \
  POWERLENS_ZSHRC="$existing_append_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  zsh "$PROJECT_ROOT/install.sh"
existing_append_status=$?

assert_eq "existing plugins append exits zero" "$existing_append_status" "0"
assert_eq "existing plugins append remains unchanged" \
  "$(<"$existing_append_zshrc")" "$existing_append_before"
assert_eq "existing plugins append creates no backup" \
  "$(count_backups "$existing_append_home")" "0"

existing_no_loader_home="$case_dir/existing-no-loader-home"
existing_no_loader_zshrc="$existing_no_loader_home/.zshrc"
existing_no_loader_install="$case_dir/existing-no-loader-install"
mkdir -p "$existing_no_loader_home"
print 'plugins=(git powerlens)' > "$existing_no_loader_zshrc"
existing_no_loader_before=$(<"$existing_no_loader_zshrc")
env -u ZSH -u ZSH_CUSTOM -u XDG_DATA_HOME \
  HOME="$existing_no_loader_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=omz \
  POWERLENS_ZSHRC="$existing_no_loader_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$existing_no_loader_install" \
  zsh "$PROJECT_ROOT/install.sh"
existing_no_loader_status=$?

assert_eq "existing plugin with no loader exits zero" \
  "$existing_no_loader_status" "0"
assert_eq "existing plugin with no loader remains unchanged" \
  "$(<"$existing_no_loader_zshrc")" "$existing_no_loader_before"
assert_eq "existing plugin with no loader creates no backup" \
  "$(count_backups "$existing_no_loader_home")" "0"

existing_multiple_loader_home="$case_dir/existing-multiple-loader-home"
existing_multiple_loader_zshrc="$existing_multiple_loader_home/.zshrc"
existing_multiple_loader_install="$case_dir/existing-multiple-loader-install"
mkdir -p "$existing_multiple_loader_home"
print 'plugins=(git powerlens)' > "$existing_multiple_loader_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$existing_multiple_loader_zshrc"
print '. "${ZSH}/oh-my-zsh.sh"' >> "$existing_multiple_loader_zshrc"
existing_multiple_loader_before=$(<"$existing_multiple_loader_zshrc")
env -u ZSH -u ZSH_CUSTOM -u XDG_DATA_HOME \
  HOME="$existing_multiple_loader_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=omz \
  POWERLENS_ZSHRC="$existing_multiple_loader_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$existing_multiple_loader_install" \
  zsh "$PROJECT_ROOT/install.sh"
existing_multiple_loader_status=$?

assert_eq "existing plugin with multiple loaders exits zero" \
  "$existing_multiple_loader_status" "0"
assert_eq "existing plugin with multiple loaders remains unchanged" \
  "$(<"$existing_multiple_loader_zshrc")" "$existing_multiple_loader_before"
assert_eq "existing plugin with multiple loaders creates no backup" \
  "$(count_backups "$existing_multiple_loader_home")" "0"

print "\n=== Ambiguous Oh My Zsh loaders ==="
ambiguous_home="$case_dir/ambiguous-home"
ambiguous_zshrc="$ambiguous_home/.zshrc"
ambiguous_error="$case_dir/ambiguous-error"
mkdir -p "$ambiguous_home"
print 'plugins=(git)' > "$ambiguous_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$ambiguous_zshrc"
print 'source "$ZSH/oh-my-zsh.sh"' >> "$ambiguous_zshrc"
ambiguous_before=$(<"$ambiguous_zshrc")

env \
  HOME="$ambiguous_home" \
  SHELL=/bin/zsh \
  ZSH_CUSTOM="$case_dir/ambiguous-custom" \
  POWERLENS_ZSHRC="$ambiguous_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  zsh "$PROJECT_ROOT/install.sh" 2>"$ambiguous_error"
ambiguous_status=$?

assert_true "ambiguous Oh My Zsh loaders exit non-zero" \
  '(( ambiguous_status != 0 ))'
assert_eq "ambiguous Oh My Zsh startup file remains unchanged" \
  "$(<"$ambiguous_zshrc")" "$ambiguous_before"
assert_contains "$ambiguous_error" "add plugins+=(powerlens) manually"

print "\n=== Missing Oh My Zsh startup file ==="
missing_zshrc_home="$case_dir/missing-zshrc-home"
missing_zshrc="$missing_zshrc_home/.zshrc"
mkdir -p "$missing_zshrc_home/.oh-my-zsh"
: > "$missing_zshrc_home/.oh-my-zsh/oh-my-zsh.sh"

env \
  HOME="$missing_zshrc_home" \
  SHELL=/bin/zsh \
  ZSH_CUSTOM="$case_dir/missing-zshrc-custom" \
  POWERLENS_ZSHRC="$missing_zshrc" \
  POWERLENS_REPO_URL="$origin" \
  zsh "$PROJECT_ROOT/install.sh"
missing_zshrc_status=$?

assert_true "missing Oh My Zsh startup file exits non-zero" \
  '(( missing_zshrc_status != 0 ))'
assert_true "missing Oh My Zsh startup file remains absent" \
  '[[ ! -e "$missing_zshrc" ]]'

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
