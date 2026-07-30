#!/usr/bin/env zsh

setopt pipefail

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
