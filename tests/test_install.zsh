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

PROJECT_ROOT=${0:A:h:h}
case_dir=$(mktemp -d)
trap 'rm -rf -- "$case_dir"' EXIT

origin="$case_dir/origin"
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
  POWERLENS_REPO_URL="$case_dir/origin" \
  POWERLENS_INSTALL_DIR="$case_dir/install" \
  zsh "$PROJECT_ROOT/install.sh"
install_status=$?

assert_eq "plain install exits zero" "$install_status" "0"
assert_file "$case_dir/install/.git"
assert_contains "$case_dir/home/.zshrc" \
  "source $case_dir/install/powerlens.plugin.zsh"
assert_eq "managed block occurs once" \
  "$(count_fixed "$case_dir/home/.zshrc" \
    '# >>> PowerLens installer >>>')" \
  "1"

env \
  HOME="$case_dir/home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$case_dir/home/.zshrc" \
  POWERLENS_REPO_URL="$case_dir/origin" \
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

print "\n=== Installation path with spaces ==="
space_home="$case_dir/home with spaces"
space_install_dir="$case_dir/install with spaces"
env \
  HOME="$space_home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$space_home/.zshrc" \
  POWERLENS_REPO_URL="$case_dir/origin" \
  POWERLENS_INSTALL_DIR="$space_install_dir" \
  zsh "$PROJECT_ROOT/install.sh"
space_install_status=$?

assert_eq "space path install exits zero" "$space_install_status" "0"
zsh -fc 'source "$1"; [[ "$POWERLENS_FIXTURE_LOADED" == 1 ]]' \
  powerlens-test "$space_home/.zshrc"
space_source_status=$?
assert_eq "space path startup file sources plugin" "$space_source_status" "0"

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
