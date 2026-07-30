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

run_installer() {
    local home_dir=$1 install_dir=$2 repo_url=$3 error_file=$4

    env \
      HOME="$home_dir" \
      SHELL=/bin/zsh \
      POWERLENS_SHELL_MODE=zsh \
      POWERLENS_ZSHRC="$home_dir/.zshrc" \
      POWERLENS_REPO_URL="$repo_url" \
      POWERLENS_INSTALL_DIR="$install_dir" \
      zsh "$PROJECT_ROOT/install.sh" 2>"$error_file"
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

print "\n=== Plain zsh installation ==="
env \
  HOME="$case_dir/home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$case_dir/home/.zshrc" \
  POWERLENS_REPO_URL="$origin" \
  POWERLENS_INSTALL_DIR="$case_dir/install" \
  zsh "$PROJECT_ROOT/install.sh"
install_status=$?

assert_eq "plain install exits zero" "$install_status" "0"
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
run_installer "$case_dir/home" "$case_dir/install" "${origin%.git}/" "$update_error"
update_status=$?

assert_eq "update exits zero" "$update_status" "0"
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

print "\n=== Installation path with spaces ==="
space_home="$case_dir/home with spaces"
space_install_dir="$case_dir/install with spaces"
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
  zsh "$PROJECT_ROOT/install.sh"
ambiguous_status=$?

assert_true "ambiguous Oh My Zsh loaders exit non-zero" \
  '(( ambiguous_status != 0 ))'
assert_eq "ambiguous Oh My Zsh startup file remains unchanged" \
  "$(<"$ambiguous_zshrc")" "$ambiguous_before"

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
