#!/usr/bin/env bash
# gitup.sh — create / update GitHub repositories from local folders, with
#            automatic Git LFS handling for large files.
#
# Usage:
#   ./gitup.sh                       process the current directory
#   ./gitup.sh --folder DIR [DIR…]   process one or more directories
#   ./gitup.sh --folder all          process every direct subfolder of $PWD
#   ./gitup.sh --all                 same as `--folder all`
#
# Options:
#   -y, --yes       don't ask questions (confirmations, installs)
#   -n, --dry-run   only show which folders / repo names would be used
#       --private   create new repositories as private (default: public)
#       --public    create new repositories as public (this is the default)
#   -h, --help      show this help
#
# Environment:
#   GITUP_YES=1                 same as --yes
#   GITUP_SKIP="a b"            extra directory names to skip in `--all` mode
#   GITUP_LFS_MB=25             files bigger than this go to Git LFS   (max 100)
#   GITUP_LFS_MAX_MB=2048       files bigger than this can't be uploaded at all
#   GITUP_RETRIES=3             attempts for network operations
#   GITUP_PKG_MANAGER=NAME      force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
#   GITUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore
#
# Self-exclusion:
#   The *currently running* script is excluded from a push only when it lives
#   inside the repo being pushed. Same-named files elsewhere (e.g. in a
#   subfolder) are pushed normally. Renaming the script (gitup.sh → gitpush.sh
#   → …) is fully supported.
#
# Works on any Linux distro (apt, dnf/yum, pacman, zypper, apk, xbps) and on
# macOS (Homebrew), including the stock bash 3.2.

# ─── guards (written in plain POSIX until we know we're in bash) ──────────────
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: gitup.sh needs bash — run it as: bash $0" >&2
    exit 1
fi

# Refuse to be sourced. Done BEFORE touching shell options.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Error: run this script as ./gitup.sh or bash gitup.sh — do not source it.\n' >&2
    # shellcheck disable=SC2317  # `exit` is the fallback when `return` is not allowed
    return 1 2>/dev/null || exit 1
fi

# NOTE: errexit is *ignored* inside anything called from an `if`/`||`/`&&`
# condition, so every critical command below is checked explicitly.
set -euo pipefail

# ─── absolute path of the running script (for self-exclusion) ─────────────────
SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _self_dir=""
    if _self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P); then
        _self_name=$(basename -- "${BASH_SOURCE[0]}")
        if [[ -n "$_self_name" && -e "$_self_dir/$_self_name" ]]; then
            SELF_PATH="$_self_dir/$_self_name"
        fi
    fi
    unset _self_dir _self_name
fi

# ─── settings ─────────────────────────────────────────────────────────────────
GH_HARD_MB=100                              # GitHub rejects bigger files outside LFS
LFS_MB="${GITUP_LFS_MB:-25}"
LFS_MAX_MB="${GITUP_LFS_MAX_MB:-2048}"      # GitHub Free/Pro LFS per-file cap
RETRIES="${GITUP_RETRIES:-3}"
ASSUME_YES=0
if [[ "${GITUP_YES:-0}" == "1" ]]; then ASSUME_YES=1; fi
DRY_RUN=0
WANT_ALL=0
VISIBILITY="public"                         # new repos; --private switches it
REQUESTED=()

GH_LOGIN=""; GH_ID=""; GH_NAME=""; GH_EMAIL=""
FOLDERS=(); SEEN=(); ALL_DIRS=(); SKIP_BIG=()
RES_URL=""; RES_NOTE=""; SELF_REL=""
SUM_DIRS=(); SUM_STATE=(); SUM_INFO=()
TMP_FILE=""

# ─── colours & logging (all to stderr) ────────────────────────────────────────
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log_info() { printf '%s[INFO]%s  %s\n' "$BLUE"   "$NC" "$*" >&2; }
log_ok()   { printf '%s[ OK ]%s  %s\n' "$GREEN"  "$NC" "$*" >&2; }
log_warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_err()  { printf '%s[FAIL]%s  %s\n' "$RED"    "$NC" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    if [[ -n "$TMP_FILE" ]]; then rm -f "$TMP_FILE"; fi
    return 0
}
trap cleanup EXIT
trap 'printf "\n" >&2; log_err "Interrupted."; exit 130' INT TERM

# Interactive prompt. Honours --yes; without a terminal it returns the default.
confirm() {
    local prompt="$1" default="${2:-n}" ans=""
    if (( ASSUME_YES )); then return 0; fi
    if [[ ! -t 0 ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n] " ans || true
        [[ -z "$ans" || "$ans" == [Yy]* ]]
    else
        read -r -p "$prompt [y/N] " ans || true
        [[ "$ans" == [Yy]* ]]
    fi
}

show_help() {
    cat <<'EOF'
gitup.sh — create / update GitHub repositories from local folders, with
automatic Git LFS handling for large files.

Usage:
  ./gitup.sh                       process the current directory
  ./gitup.sh --folder DIR [DIR…]   process one or more directories
  ./gitup.sh --folder all          process every direct subfolder of $PWD
  ./gitup.sh --all                 same as `--folder all`
  ./gitup.sh DIR [DIR…]            shorthand for --folder

Options:
  -y, --yes       don't ask questions (confirmations, installs)
  -n, --dry-run   only show which folders / repo names would be used
      --private   create new repositories as private (default: public)
      --public    create new repositories as public (this is the default)
  -h, --help      show this help

Environment:
  GITUP_YES=1                 same as --yes
  GITUP_SKIP="a b"            extra directory names to skip in `--all` mode
  GITUP_LFS_MB=25             files bigger than this go to Git LFS (max 100)
  GITUP_LFS_MAX_MB=2048       files bigger than this can't be uploaded at all
  GITUP_RETRIES=3             attempts for network operations
  GITUP_PKG_MANAGER=NAME      force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
  GITUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore

How it works:
  • Each folder becomes its own repository, named after the folder
    (spaces → '-', unsupported characters removed).
  • No .git yet → one is created.  Existing .git → it is simply updated.
  • Files over GITUP_LFS_MB are stored with Git LFS automatically.
  • A repo without a .gitignore skips node_modules, __pycache__, .venv,
    .DS_Store and Thumbs.db (local exclude only; nothing is added to the repo).
  • In `--all` mode hidden folders, symlinks, empty folders and common
    build/dependency folders (node_modules, .venv, dist, build, target, …)
    are skipped.  Naming a folder explicitly always processes it.
  • A folder literally called `all` can be processed with `--folder ./all`.

Self-exclusion:
  The running script is excluded from a push only when it lives inside the
  repo being pushed. Same-named files elsewhere are pushed. Renaming the
  script is supported.
EOF
}

# ─── tiny helpers ─────────────────────────────────────────────────────────────
run_privileged() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    elif command_exists doas; then
        doas "$@"
    else
        log_err "Root privileges are needed to run: $*  (install sudo or run as root)"
        return 1
    fi
}

fetch_url() {
    if command_exists curl; then
        curl -fsSL "$1"
    elif command_exists wget; then
        wget -qO- "$1"
    else
        log_err "curl or wget is needed to download $1"
        return 1
    fi
}

# Escape characters that are special in .gitignore patterns.
gitignore_escape() { printf '%s' "$1" | sed -e 's/[][*?\\]/\\&/g'; }

# Append a line to an exclude file unless already present.
exclude_add() {
    mkdir -p "$(dirname -- "$1")" 2>/dev/null || return 1
    touch "$1" 2>/dev/null || return 1
    if ! grep -qxF -- "$2" "$1" 2>/dev/null; then
        printf '%s\n' "$2" >> "$1" || return 1
    fi
    return 0
}

# ─── package managers ─────────────────────────────────────────────────────────
ensure_brew_on_path() {
    local b
    if command_exists brew; then return 0; fi
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew \
             /home/linuxbrew/.linuxbrew/bin/brew "${HOME:-/nonexistent}/.linuxbrew/bin/brew"; do
        if [[ -x "$b" ]]; then
            eval "$("$b" shellenv)"
            hash -r 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

detect_pkg_manager() {
    local m
    if [[ -n "${GITUP_PKG_MANAGER:-}" ]]; then
        printf '%s\n' "$GITUP_PKG_MANAGER"
        return 0
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command_exists brew; then echo brew; fi
        return 0
    fi
    for m in apt-get dnf yum pacman zypper apk xbps-install brew; do
        if command_exists "$m"; then
            echo "$m"
            return 0
        fi
    done
    return 0
}

# Distro package name for a tool (Arch/Alpine/Void call gh "github-cli").
pkg_name_for() {
    case "$2" in
        gh)
            case "$1" in
                pacman|apk|xbps-install) echo github-cli ;;
                *) echo gh ;;
            esac ;;
        *) echo "$2" ;;
    esac
}

install_with_mgr() {
    local mgr="$1"; shift
    case "$mgr" in
        apt-get)
            if ! run_privileged apt-get update -qq; then
                log_warn "'apt-get update' failed — trying to install anyway."
            fi
            run_privileged apt-get install -y "$@" ;;
        dnf)          run_privileged dnf install -y "$@" ;;
        yum)          run_privileged yum install -y "$@" ;;
        pacman)       run_privileged pacman -S --noconfirm --needed "$@" ;;
        zypper)       run_privileged zypper --non-interactive install "$@" ;;
        apk)          run_privileged apk add "$@" ;;
        xbps-install) run_privileged xbps-install -y "$@" ;;
        brew)         brew install "$@" ;;
        *)            log_err "Unsupported package manager: $mgr"; return 1 ;;
    esac
}

# GitHub's official package repositories, for distros whose own repos lack `gh`.
add_gh_official_repo() {
    local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg" arch
    case "$1" in
        apt-get)
            arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
            run_privileged mkdir -p -m 755 /etc/apt/keyrings || return 1
            fetch_url https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | run_privileged tee "$keyring" >/dev/null || return 1
            run_privileged chmod go+r "$keyring" || return 1
            printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' "$arch" "$keyring" \
                | run_privileged tee /etc/apt/sources.list.d/github-cli.list >/dev/null || return 1
            run_privileged apt-get update -qq ;;
        dnf|yum)
            fetch_url https://cli.github.com/packages/rpm/gh-cli.repo \
                | run_privileged tee /etc/yum.repos.d/gh-cli.repo >/dev/null ;;
        zypper)
            run_privileged zypper --non-interactive addrepo https://cli.github.com/packages/rpm/gh-cli.repo || return 1
            run_privileged zypper --non-interactive --gpg-auto-import-keys refresh ;;
        *) return 1 ;;
    esac
}

print_manual_hint() {
    case "$1" in
        git)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                log_err "Install git with:  xcode-select --install   (or: brew install git)"
            else
                log_err "Install git with your package manager, then re-run."
            fi ;;
        gh)      log_err "Install the GitHub CLI: https://github.com/cli/cli#installation" ;;
        git-lfs) log_err "Install Git LFS: https://git-lfs.com" ;;
    esac
    if [[ "$(uname -s)" == "Darwin" ]] && ! command_exists brew; then
        log_err "Homebrew is not installed — get it from https://brew.sh and re-run."
    fi
}

install_tool() {
    local tool="$1" mgr pkg
    mgr=$(detect_pkg_manager)
    if [[ -z "$mgr" ]]; then
        log_err "No supported package manager found (apt, dnf, yum, pacman, zypper, apk, xbps, brew)."
        print_manual_hint "$tool"
        return 1
    fi
    pkg=$(pkg_name_for "$mgr" "$tool")
    log_info "Installing '$pkg' via $mgr…"
    if install_with_mgr "$mgr" "$pkg"; then
        hash -r 2>/dev/null || true
        return 0
    fi
    if [[ "$tool" == "gh" ]]; then
        case "$mgr" in
            apt-get|dnf|yum|zypper)
                log_warn "'gh' is not available from the distro repositories — adding GitHub's official package repository."
                if add_gh_official_repo "$mgr" && install_with_mgr "$mgr" "$pkg"; then
                    hash -r 2>/dev/null || true
                    return 0
                fi ;;
        esac
    fi
    if [[ "$mgr" == "pacman" ]]; then
        log_warn "If pacman could not find or fetch the package, update first:  sudo pacman -Syu"
    fi
    print_manual_hint "$tool"
    return 1
}

git_usable() { command_exists git && git --version >/dev/null 2>&1; }

ensure_dependencies() {
    local -a missing=()
    local tool
    ensure_brew_on_path || true
    if ! git_usable; then missing+=("git"); fi
    if ! command_exists gh; then missing+=("gh"); fi
    if (( ${#missing[@]} == 0 )); then
        log_ok "git and gh are installed."
        return 0
    fi
    log_warn "Missing dependencies: ${missing[*]}"
    if ! confirm "Install them now using your package manager? (you may be asked for your password)" n; then
        die "git and gh are required. Aborting."
    fi
    for tool in "${missing[@]}"; do
        install_tool "$tool" || die "Installation of '$tool' failed."
    done
    git_usable || die "git is still not usable after installation."
    command_exists gh || die "gh is still not available after installation."
    log_ok "Dependencies installed."
}

# ─── GitHub auth & identity ───────────────────────────────────────────────────
ensure_auth() {
    if gh auth status --hostname github.com >/dev/null 2>&1; then
        log_ok "GitHub CLI is authenticated."
    else
        log_warn "GitHub CLI is not logged in — starting 'gh auth login'…"
        if [[ ! -t 0 ]]; then
            die "No terminal available for login. Run 'gh auth login' first, or set GH_TOKEN."
        fi
        gh auth login --hostname github.com || die "Authentication failed."
        gh auth status --hostname github.com >/dev/null 2>&1 || die "Still not authenticated after login."
        log_ok "Authentication successful."
    fi
    gh auth setup-git >/dev/null 2>&1 || true
}

load_github_identity() {
    local out=""
    if ! out=$(gh api user --jq '.login, .id, (.name // "")' 2>&1); then
        die "Could not query your GitHub account: $out"
    fi
    { IFS= read -r GH_LOGIN; IFS= read -r GH_ID; IFS= read -r GH_NAME; } <<EOF || true
$out
EOF
    if [[ -z "$GH_LOGIN" ]]; then die "GitHub returned no username. Try: gh auth status"; fi
    if [[ -z "$GH_NAME" ]]; then GH_NAME="$GH_LOGIN"; fi
    case "$GH_ID" in
        ''|*[!0-9]*) GH_EMAIL="${GH_LOGIN}@users.noreply.github.com" ;;
        *)           GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com" ;;
    esac
}

ensure_git_identity() {
    local n e
    n=$(git config user.name  2>/dev/null || true)
    e=$(git config user.email 2>/dev/null || true)
    if [[ -n "$n" && -n "$e" ]]; then return 0; fi
    if [[ -z "$n" ]]; then git config user.name  "$GH_NAME"  || return 1; fi
    if [[ -z "$e" ]]; then git config user.email "$GH_EMAIL" || return 1; fi
    log_info "No git identity configured — using your GitHub identity for this repo."
}

# ─── Git LFS ──────────────────────────────────────────────────────────────────
have_lfs() { git lfs version >/dev/null 2>&1; }

repo_uses_lfs() { [[ -f .gitattributes ]] && grep -q 'filter=lfs' .gitattributes 2>/dev/null; }

ensure_lfs() {
    if have_lfs; then return 0; fi
    log_warn "Git LFS is needed to upload files larger than ${LFS_MB} MB."
    if ! confirm "Install Git LFS now?" n; then return 1; fi
    install_tool git-lfs || return 1
    if have_lfs; then return 0; fi
    log_err "Git LFS was installed but is not on PATH."
    return 1
}

lfs_activate() {
    if ! git lfs install --local >/dev/null 2>&1; then
        log_warn "'git lfs install --local' reported a problem (existing hooks?) — gitup will upload LFS objects explicitly."
    fi
    if [[ -z "$(git config --get filter.lfs.clean 2>/dev/null || true)" ]]; then
        log_err "Git LFS filter is not configured for this repository."
        return 1
    fi
}

file_size_mb() { echo $(( $(wc -c < "$1") / 1048576 )); }

# true if file $1 is bigger than $2 MiB (portable: GNU and BSD find)
file_over_mb() { [[ -n "$(find "$1" -maxdepth 0 -type f -size "+$2M" -print 2>/dev/null)" ]]; }

# true if git would stage this path (tracked, or untracked and not ignored)
path_is_addable() {
    [[ -n "$(GIT_LITERAL_PATHSPECS=1 git ls-files --cached --others --exclude-standard -- "$1" 2>/dev/null)" ]]
}

# Finds files that need LFS (or can't be uploaded), prepares LFS tracking.
# Fills SKIP_BIG with files above the LFS cap. Returns 1 on a fatal problem.
prepare_large_files() {
    local f rel mb attr hard=0
    local -a candidates=()
    SKIP_BIG=()

    while IFS= read -r -d '' f; do
        if ! path_is_addable "$f"; then continue; fi
        if file_over_mb "$f" "$LFS_MAX_MB"; then
            SKIP_BIG+=("$f")
            continue
        fi
        candidates+=("$f")
        if file_over_mb "$f" "$GH_HARD_MB"; then hard=1; fi
    done < <(find . -name .git -prune -o -type f -size "+${LFS_MB}M" -print0 2>/dev/null)

    if (( ${#SKIP_BIG[@]} )); then
        for f in "${SKIP_BIG[@]}"; do
            log_warn "Too large for GitHub (over ${LFS_MAX_MB} MB, $(file_size_mb "$f") MB) — NOT uploaded: ${f#./}"
        done
    fi

    if (( ${#candidates[@]} == 0 )) && ! repo_uses_lfs; then return 0; fi

    if ! have_lfs; then
        if ! ensure_lfs; then
            if repo_uses_lfs; then
                log_err "This repository already uses Git LFS, which is not available — refusing to commit raw files."
                return 1
            fi
            if (( hard )); then
                log_err "Files over ${GH_HARD_MB} MB can't be pushed to GitHub without Git LFS:"
                for f in "${candidates[@]}"; do
                    if file_over_mb "$f" "$GH_HARD_MB"; then log_err "  ${f#./}"; fi
                done
                return 1
            fi
            log_warn "Git LFS unavailable — files over ${LFS_MB} MB will be committed normally (GitHub warns above 50 MB)."
            return 0
        fi
    fi

    lfs_activate || return 1

    if (( ${#candidates[@]} )); then
        log_info "Using Git LFS for files larger than ${LFS_MB} MB:"
        for f in "${candidates[@]}"; do
            rel="${f#./}"
            mb=$(file_size_mb "$f")
            attr=$(git check-attr filter -- "$f" 2>/dev/null || true)
            if [[ "$attr" == *": filter: lfs" ]]; then
                log_info "  = $rel (${mb} MB, already tracked)"
                continue
            fi
            if git lfs track --filename -- "$f" >/dev/null 2>&1; then
                log_info "  + $rel (${mb} MB)"
            else
                log_err "  ! could not track $rel with Git LFS"
                return 1
            fi
        done
    fi
    return 0
}

# ─── network operations with retry ────────────────────────────────────────────
is_transient_failure() {
    grep -Eqi 'RPC failed|early EOF|unexpected disconnect|remote end hung up|reset by peer|timed out|timeout|Could not resolve host|Could not connect|Failed to connect|Connection (closed|refused|reset)|Broken pipe|HTTP/2 stream|SSL_|GnuTLS|(error|status|HTTP|returned error:) 5[0-9][0-9]' "$1"
}

# run_with_retry LABEL cmd…   (output is shown live and kept in $TMP_FILE)
run_with_retry() {
    local label="$1" attempt=1 rc delay
    shift
    while true; do
        rc=0
        "$@" 2>&1 | tee "$TMP_FILE" >&2 || rc=$?
        if (( rc == 0 )); then return 0; fi
        if (( attempt >= RETRIES )) || ! is_transient_failure "$TMP_FILE"; then
            return "$rc"
        fi
        delay=$(( attempt * 4 ))
        attempt=$(( attempt + 1 ))
        log_warn "$label failed (network problem?) — retrying in ${delay}s (attempt ${attempt}/${RETRIES})…"
        sleep "$delay"
    done
}

diagnose_push_failure() {
    local f="$1" branch="$2"
    if grep -Eqi 'GH001|exceeds GitHub.s file size limit|Large files detected' "$f"; then
        log_err "A file over ${GH_HARD_MB} MB is stored in the commit history without Git LFS."
        log_err "If this repo was never pushed (nobody else has a copy), rewrite its history once:"
        log_err "    git lfs migrate import --everything --above=${GH_HARD_MB}MB"
        log_err "then run this script again."
    elif grep -Eqi 'workflow.*scope|without .?workflow.? scope' "$f"; then
        log_err "GitHub refused workflow files (.github/workflows) — your login lacks the 'workflow' scope."
        log_err "Fix:  gh auth refresh -h github.com -s workflow"
    elif grep -Eqi 'GH013|push cannot contain secrets|secret scanning' "$f"; then
        log_err "GitHub blocked the push (secret scanning / repository rule). Read the message above,"
        log_err "remove the flagged secret from your files and commit, then re-run."
    elif grep -Eqi 'quota|over its data|LFS.*(budget|limit exceeded)' "$f"; then
        log_err "GitHub LFS storage/bandwidth quota exceeded. Free accounts get limited LFS data."
        log_err "Buy more LFS data on GitHub, delete old LFS objects, or raise GITUP_LFS_MB so mid-size files skip LFS."
    elif grep -Eqi 'non-fast-forward|fetch first|tip of your current branch is behind' "$f"; then
        if (( ATTACHED )); then
            log_err "The GitHub repo already exists and has a different history than this folder."
            log_err "Either rename the folder (repo names follow folder names) or merge manually:"
        else
            log_err "The remote branch has commits that this folder doesn't have. Merge them first:"
        fi
        log_err "    git pull --no-rebase --allow-unrelated-histories origin ${branch}"
        log_err "then run this script again. (gitup never force-pushes.)"
    elif grep -Eqi 'Authentication failed|could not read (Username|Password)|Permission denied \(publickey\)|HTTP Basic: Access denied|Support for password authentication|returned error: 403|invalid credentials' "$f"; then
        log_err "GitHub rejected your credentials. Try:  gh auth login   and   gh auth setup-git"
    elif grep -Eqi 'Repository not found|does not appear to be a git repository' "$f"; then
        log_err "The remote repository was not found. Check 'git remote -v' — it may have been deleted or renamed."
    else
        log_err "Push failed — see the git output above."
    fi
}

push_branch() {
    local remote="$1" branch="$2"
    if have_lfs && repo_uses_lfs; then
        log_info "Uploading Git LFS objects to '$remote'…"
        if ! run_with_retry "LFS upload" git lfs push "$remote" "$branch"; then
            diagnose_push_failure "$TMP_FILE" "$branch"
            return 1
        fi
    fi
    log_info "Pushing '$branch' to '$remote'…"
    if ! run_with_retry "git push" git push --progress -u "$remote" "$branch"; then
        diagnose_push_failure "$TMP_FILE" "$branch"
        return 1
    fi
    return 0
}

# ─── repo naming & remote setup ───────────────────────────────────────────────
sanitize_repo_name() {
    local n
    n=$(printf '%s' "$1" | LC_ALL=C tr ' ' '-' | LC_ALL=C tr -cd 'A-Za-z0-9._-')
    n="${n%.git}"
    n="${n:0:100}"
    case "$n" in
        '') return 1 ;;
        *[!.]*) ;;          # contains something other than dots → fine
        *) return 1 ;;      # only dots ('.', '..')
    esac
    printf '%s' "$n"
}

web_url() {
    printf '%s' "$1" | sed -e 's#^git@github\.com:#https://github.com/#' \
                           -e 's#^ssh://git@github\.com/#https://github.com/#' \
                           -e 's#\.git$##'
}

# Sets REMOTE_NAME, REMOTE_URL, RES_URL, ATTACHED, RES_NOTE (creates/attaches repo if needed)
setup_remote() {
    local dir="$1" base repo_name out rc=0 clone ssh html proto other
    ATTACHED=0
    REMOTE_NAME="origin"
    REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "$REMOTE_URL" ]]; then
        RES_URL=$(web_url "$REMOTE_URL")
        log_info "Using existing remote 'origin' → $REMOTE_URL"
        return 0
    fi
    other=$(git remote 2>/dev/null | head -n 1 || true)
    if [[ -n "$other" ]]; then
        REMOTE_NAME="$other"
        REMOTE_URL=$(git config --get "remote.$other.url" 2>/dev/null || true)
        if [[ -n "$REMOTE_URL" ]]; then
            RES_URL=$(web_url "$REMOTE_URL")
            log_info "Using existing remote '$other' → $REMOTE_URL"
            return 0
        fi
    fi

    base=$(basename -- "$dir")
    if ! repo_name=$(sanitize_repo_name "$base"); then
        log_err "Cannot derive a valid GitHub repository name from folder '$base' (use letters, digits, '.', '_' or '-')."
        return 1
    fi
    if [[ "$repo_name" != "$base" ]]; then
        log_warn "Repository name sanitised: '$base' → '$repo_name'."
    fi

    out=$(gh api "repos/$GH_LOGIN/$repo_name" --jq '.clone_url, .ssh_url, .html_url' 2>&1) || rc=$?
    if (( rc == 0 )); then
        ATTACHED=1
        log_warn "GitHub repo '$GH_LOGIN/$repo_name' already exists — attaching to it."
        RES_NOTE="attached to existing repo"
    elif [[ "$out" == *"404"* || "$out" == *"Not Found"* ]]; then
        rc=0
        log_info "Creating ${VISIBILITY} GitHub repository '$repo_name'…"
        local private_flag="true"
        if [[ "$VISIBILITY" == "public" ]]; then private_flag="false"; fi
        if ! out=$(gh api --method POST user/repos -f name="$repo_name" -F private="$private_flag" \
                        --jq '.clone_url, .ssh_url, .html_url' 2>&1); then
            log_err "Could not create repository '$repo_name': $out"
            return 1
        fi
        log_ok "Created repository $GH_LOGIN/$repo_name (${VISIBILITY})."
        RES_NOTE="created"
    else
        log_err "Could not check GitHub for '$repo_name': $out"
        return 1
    fi

    clone=$(printf '%s\n' "$out" | sed -n '1p')
    ssh=$(printf '%s\n' "$out" | sed -n '2p')
    html=$(printf '%s\n' "$out" | sed -n '3p')
    proto=$(gh config get git_protocol 2>/dev/null || true)
    if [[ "$proto" == "ssh" && -n "$ssh" ]]; then REMOTE_URL="$ssh"; else REMOTE_URL="$clone"; fi
    if [[ -z "$REMOTE_URL" ]]; then
        log_err "GitHub did not return a clone URL for '$repo_name'."
        return 1
    fi
    RES_URL="$html"
    if [[ -z "$RES_URL" ]]; then RES_URL=$(web_url "$REMOTE_URL"); fi
    git remote add "$REMOTE_NAME" "$REMOTE_URL" || return 1
    return 0
}

# ─── folder discovery ─────────────────────────────────────────────────────────
DEFAULT_SKIP_DIRS=(
    node_modules __pycache__ .venv venv env virtualenv
    dist build out target bin obj
    .idea .vscode .vs .history
    .cache .pytest_cache .mypy_cache .ruff_cache .tox
    vendor .next .nuxt .svelte-kit .turbo
)

is_skipped_dir() {
    local name="$1" skip
    local -a extra=()
    if [[ "$name" == .* ]]; then return 0; fi
    for skip in "${DEFAULT_SKIP_DIRS[@]}"; do
        if [[ "$name" == "$skip" ]]; then return 0; fi
    done
    if [[ -n "${GITUP_SKIP:-}" ]]; then
        IFS=' ,' read -r -a extra <<< "$GITUP_SKIP" || true
        if (( ${#extra[@]} )); then
            for skip in "${extra[@]}"; do
                if [[ "$name" == "$skip" ]]; then return 0; fi
            done
        fi
    fi
    return 1
}

# Fills ALL_DIRS with the direct subfolders of $PWD that should be processed.
enumerate_all_subfolders() {
    local d name
    ALL_DIRS=()
    for d in */; do
        [[ -d "$d" ]] || continue
        name="${d%/}"
        if [[ -L "$name" ]]; then
            log_warn "Skipping '$name' (symbolic link)."
            continue
        fi
        if is_skipped_dir "$name"; then
            log_warn "Skipping '$name' (build/dependency/ignored folder)."
            continue
        fi
        if [[ -z "$(ls -A "$name" 2>/dev/null)" ]]; then
            log_warn "Skipping '$name' (empty folder)."
            continue
        fi
        ALL_DIRS+=("$name")
    done
}

# Adds a folder (absolute path) to FOLDERS unless the same directory is already there.
add_folder() {
    local abs key s
    abs=$(cd -- "$1" 2>/dev/null && pwd) || return 0
    key=$(cd -- "$1" 2>/dev/null && pwd -P) || return 0
    if (( ${#SEEN[@]} )); then
        for s in "${SEEN[@]}"; do
            if [[ "$s" == "$key" ]]; then return 0; fi
        done
    fi
    SEEN+=("$key")
    FOLDERS+=("$abs")
}

# ─── per-folder work ──────────────────────────────────────────────────────────
# Returns 0 = done, 1 = failed, 2 = skipped (nothing to upload).
process_dir_impl() {
    local dir="$1" phys branch gp excl parent err pat rel f msg risky
    local self_base tmp grep_rc
    local -a addargs=()
    RES_URL=""; RES_NOTE=""; SELF_REL=""; ATTACHED=0

    phys=$(pwd -P)

    # 1. repository ----------------------------------------------------------
    if [[ -e .git ]]; then
        if ! err=$(git rev-parse --git-dir 2>&1 >/dev/null); then
            log_err "'.git' exists but git cannot use it: $err"
            return 1
        fi
        log_info "Existing git repository."
    else
        parent=$(git rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -n "$parent" ]]; then
            log_warn "This folder sits inside another git repository ($parent) — creating a separate repository here."
        fi
        if ! git init -q; then log_err "git init failed."; return 1; fi
        if [[ -z "$(git config --get init.defaultBranch 2>/dev/null || true)" ]]; then
            git symbolic-ref HEAD refs/heads/main || return 1
        fi
        log_ok "Initialised a new git repository."
    fi

    # 2. branch must be sane -------------------------------------------------
    if ! branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null); then
        log_err "HEAD is detached. Check out a branch first (e.g. 'git switch main') and re-run."
        return 1
    fi
    for gp in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        if [[ -e "$(git rev-parse --git-path "$gp" 2>/dev/null)" ]]; then
            log_err "A merge/rebase/cherry-pick is in progress ($gp). Finish or abort it first."
            return 1
        fi
    done

    # 3. identity ------------------------------------------------------------
    ensure_git_identity || { log_err "Could not set a git identity."; return 1; }

    # 4. local-only excludes (never committed) --------------------------------
    excl=$(git rev-parse --git-path info/exclude 2>/dev/null || true)
    if [[ -z "$excl" ]]; then excl=".git/info/exclude"; fi

    # 4a. running script: excluded only if it lives inside this repo
    case "$SELF_PATH" in
        "$phys"/*) SELF_REL="${SELF_PATH#"$phys"/}" ;;
    esac
    if [[ -n "$SELF_REL" ]]; then
        # An older gitup wrote an *unanchored* rule (just the file name), which also
        # hid same-named files in subfolders. Drop it; the anchored rule replaces it.
        self_base=$(basename -- "$SELF_REL")
        if grep -qxF -- "$self_base" "$excl" 2>/dev/null; then
            tmp="${excl}.gitup.$$"
            grep_rc=0
            grep -vxF -- "$self_base" "$excl" > "$tmp" 2>/dev/null || grep_rc=$?
            case $grep_rc in
                0) mv -f "$tmp" "$excl" ;;
                1) : > "$excl"; rm -f "$tmp" ;;
                *) rm -f "$tmp"; log_warn "Could not rewrite $excl (grep status $grep_rc)." ;;
            esac
            log_info "Removed an old unanchored exclude rule: $self_base"
        fi
        if exclude_add "$excl" "/$(gitignore_escape "$SELF_REL")"; then
            log_info "Not uploading the running script: $SELF_REL"
        fi
        # committed by an earlier run? untrack it
        if GIT_LITERAL_PATHSPECS=1 git ls-files --error-unmatch -- "$SELF_REL" >/dev/null 2>&1; then
            if GIT_LITERAL_PATHSPECS=1 git rm --cached -f -q -- "$SELF_REL"; then
                log_info "Untracked the running script (an earlier run had committed it): $SELF_REL"
            else
                log_warn "Could not untrack $SELF_REL"
            fi
        fi
    fi

    # 4b. sensible defaults for projects that have no .gitignore at all
    if [[ ! -e .gitignore && -z "${GITUP_NO_DEFAULT_IGNORE:-}" ]]; then
        if ! grep -qxF '# gitup: default ignores' "$excl" 2>/dev/null; then
            exclude_add "$excl" '# gitup: default ignores' || true
            for pat in .DS_Store Thumbs.db node_modules/ __pycache__/ '*.pyc' .venv/; do
                exclude_add "$excl" "$pat" || true
            done
            log_info "No .gitignore found — skipping node_modules, __pycache__, .venv, .DS_Store, Thumbs.db."
        fi
    fi

    # 5. large files -----------------------------------------------------------
    prepare_large_files || return 1

    # 6. stage -----------------------------------------------------------------
    addargs=(-A -- .)
    if (( ${#SKIP_BIG[@]} )); then
        for f in "${SKIP_BIG[@]}"; do addargs+=(":(exclude,literal)${f#./}"); done
    fi
    # (the running script needs no pathspec: its exclude rule + untracking above keep it out,
    #  and naming an *ignored* path in a pathspec would make `git add` abort)
    if ! git add "${addargs[@]}"; then
        log_err "git add failed."
        return 1
    fi

    # 7. heads-up about things people rarely want in a repo ---------------------
    # Newly added files only (already-tracked ones were decided on earlier runs).
    risky=$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
            | grep -Ei '(^|/)(\.env|\.env\.[A-Za-z0-9_-]+|id_rsa|id_dsa|id_ecdsa|id_ed25519|[^/]*\.pem|[^/]*\.p12|[^/]*\.pfx|[^/]*\.key)$' \
            | grep -Eiv '\.(example|sample|template|dist)$' | head -n 5 || true)
    if [[ -n "$risky" ]]; then
        log_warn "These new files look like secrets/credentials:"
        printf '%s\n' "$risky" | while IFS= read -r f; do log_warn "    $f"; done
        if [[ "$VISIBILITY" == "public" ]]; then
            log_warn "New repositories are PUBLIC by default — anyone could read these files."
        fi
        if ! confirm "Upload them anyway?" n; then
            if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
                git reset -q || true
            else
                git rm -r -q --cached -f --ignore-unmatch -- . >/dev/null 2>&1 || true
            fi
            log_warn "Skipped '$dir'. Add those files to .gitignore and re-run (or use -y to upload anyway)."
            RES_NOTE="possible secrets — not uploaded"
            return 2
        fi
    fi
    risky=$(git diff --cached --raw --diff-filter=A 2>/dev/null | grep -E '^:[0-7]+ 160000 ' | cut -f2 | head -n 5 || true)
    if [[ -n "$risky" ]]; then
        log_warn "Nested git repositories were added as empty links (their files are NOT uploaded):"
        printf '%s\n' "$risky" | while IFS= read -r f; do log_warn "    $f"; done
    fi

    # 8. commit ----------------------------------------------------------------
    if git diff --cached --quiet; then
        log_info "No new changes to commit."
    else
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
            msg="Update from gitup.sh $(date '+%Y-%m-%d %H:%M:%S')"
        else
            msg="Initial commit"
        fi
        if ! git commit -q -m "$msg"; then
            log_err "git commit failed."
            return 1
        fi
        log_ok "Committed local changes."
    fi
    if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        log_warn "Nothing to upload in '$dir' (empty, or everything is ignored) — skipped."
        RES_NOTE="nothing to upload"
        return 2
    fi

    # 9. remote + push ----------------------------------------------------------
    setup_remote "$dir" || return 1
    push_branch "$REMOTE_NAME" "$branch" || return 1
    if [[ -z "$RES_NOTE" ]]; then RES_NOTE="pushed"; fi
    log_ok "Done: $RES_URL"
    return 0
}

process_directory() {
    local dir="$1" prev="$PWD" rc=0
    RES_URL=""; RES_NOTE=""
    if ! cd -- "$dir"; then
        log_err "Cannot enter '$dir'"
        return 1
    fi
    process_dir_impl "$dir" || rc=$?
    cd -- "$prev" 2>/dev/null || true
    return "$rc"
}

# ─── argument parsing & main ──────────────────────────────────────────────────
parse_args() {
    local got
    while (( $# )); do
        case "$1" in
            -h|--help)    show_help; exit 0 ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            --all)        WANT_ALL=1; shift ;;
            --public)     VISIBILITY="public"; shift ;;
            --private)    VISIBILITY="private"; shift ;;
            --folder|--folders)
                shift
                got=0
                while (( $# )) && [[ "$1" != -* ]]; do
                    REQUESTED+=("$1"); got=1; shift
                done
                if (( ! got )); then
                    die "--folder needs at least one directory (or 'all'). Folder names starting with '-' must be written as ./-name"
                fi ;;
            --folder=*)
                if [[ -z "${1#--folder=}" ]]; then die "--folder= needs a directory."; fi
                REQUESTED+=("${1#--folder=}"); shift ;;
            --)
                shift
                while (( $# )); do REQUESTED+=("$1"); shift; done ;;
            -*)
                die "Unknown option: $1 (try --help)" ;;
            *)
                REQUESTED+=("$1"); shift ;;
        esac
    done
}

validate_settings() {
    local re='^[0-9]+$'
    if ! [[ "$LFS_MB" =~ $re ]] || (( LFS_MB < 1 )); then die "GITUP_LFS_MB must be a positive whole number."; fi
    if ! [[ "$LFS_MAX_MB" =~ $re ]] || (( LFS_MAX_MB < 1 )); then die "GITUP_LFS_MAX_MB must be a positive whole number."; fi
    if ! [[ "$RETRIES" =~ $re ]] || (( RETRIES < 1 )); then die "GITUP_RETRIES must be a positive whole number."; fi
    if (( LFS_MB > GH_HARD_MB )); then
        log_warn "GITUP_LFS_MB=${LFS_MB} is above GitHub's ${GH_HARD_MB} MB file limit — using ${GH_HARD_MB}."
        LFS_MB=$GH_HARD_MB
    fi
}

build_folder_list() {
    local a d have_all=0 expanded=0
    local -a missing=()

    if (( ${#REQUESTED[@]} )); then
        for a in "${REQUESTED[@]}"; do
            if [[ "$a" == "all" ]]; then have_all=1; fi
        done
    fi

    if (( WANT_ALL || have_all )); then
        expanded=1
        log_info "Expanding 'all' — scanning $PWD for direct subfolders…"
        if (( have_all )) && [[ -d all ]]; then
            log_info "Note: a folder literally named 'all' exists too; use ./all to process only that one."
        fi
        enumerate_all_subfolders
        if (( ${#ALL_DIRS[@]} )); then
            for d in "${ALL_DIRS[@]}"; do add_folder "$d"; done
        fi
    fi

    if (( ${#REQUESTED[@]} )); then
        for a in "${REQUESTED[@]}"; do
            if [[ "$a" == "all" ]]; then continue; fi
            if [[ -z "$a" || ! -d "$a" ]]; then missing+=("$a"); continue; fi
            add_folder "$a"
        done
    fi
    if (( ${#missing[@]} )); then
        for a in "${missing[@]}"; do log_err "Not a directory: '$a'"; done
        die "Nothing was uploaded. Fix the folder name(s) above and re-run."
    fi

    if (( ! WANT_ALL && ! have_all && ${#REQUESTED[@]} == 0 )); then
        add_folder "$PWD"
    fi

    if (( ${#FOLDERS[@]} == 0 )); then
        if (( expanded )); then die "No subfolders to process in $PWD (all were empty or skipped)."; fi
        die "No folders to process."
    fi

    EXPANDED=$expanded
}

main() {
    local f i total rc failures=0 skipped=0 shown label
    EXPANDED=0
    parse_args "$@"
    validate_settings
    build_folder_list
    total=${#FOLDERS[@]}

    if (( DRY_RUN )); then
        log_info "Dry run — ${total} folder(s) would be processed (new repositories: ${VISIBILITY}):"
        for f in "${FOLDERS[@]}"; do
            if [[ -e "$f/.git" ]]; then
                label="existing repo"
            else
                label="new repo: $(sanitize_repo_name "$(basename -- "$f")" || echo '(invalid name)')"
            fi
            log_info "  • $f   [$label]"
        done
        exit 0
    fi

    if (( EXPANDED && total > 5 )); then
        log_info "Will process ${total} folders:"
        shown=0
        for f in "${FOLDERS[@]}"; do
            if (( shown < 10 )); then
                log_info "  • $(basename -- "$f")"
                shown=$(( shown + 1 ))
            else
                log_info "  … and $(( total - shown )) more"
                break
            fi
        done
        if ! confirm "Proceed?" y; then
            log_warn "Aborted."
            exit 0
        fi
    fi

    if [[ ! -t 0 ]]; then export GIT_TERMINAL_PROMPT=0; fi
    export GIT_LFS_FORCE_PROGRESS=1
    TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/gitup.XXXXXX") || die "Cannot create a temporary file."

    ensure_dependencies
    ensure_auth
    load_github_identity
    log_info "Signed in to GitHub as ${GH_LOGIN}."

    i=0
    for f in "${FOLDERS[@]}"; do
        i=$(( i + 1 ))
        printf '\n' >&2
        log_info "[${i}/${total}] $(basename -- "$f")"
        rc=0
        process_directory "$f" || rc=$?
        SUM_DIRS+=("$(basename -- "$f")")
        case $rc in
            0) SUM_STATE+=("OK");   SUM_INFO+=("${RES_URL}") ;;
            2) SUM_STATE+=("SKIP"); SUM_INFO+=("${RES_NOTE}"); skipped=$(( skipped + 1 )) ;;
            *) SUM_STATE+=("FAIL"); SUM_INFO+=("see messages above"); failures=$(( failures + 1 )) ;;
        esac
    done

    printf '\n' >&2
    log_info "Summary"
    for (( i = 0; i < total; i++ )); do
        case "${SUM_STATE[$i]}" in
            OK)   log_ok   "${SUM_DIRS[$i]}  →  ${SUM_INFO[$i]}" ;;
            SKIP) log_warn "${SUM_DIRS[$i]}  →  skipped (${SUM_INFO[$i]})" ;;
            *)    log_err  "${SUM_DIRS[$i]}  →  failed" ;;
        esac
    done

    if (( failures > 0 )); then
        log_err "${failures} of ${total} folder(s) failed."
        exit 1
    fi
    log_ok "Done — $(( total - skipped )) of ${total} folder(s) uploaded."
}

main "$@"
