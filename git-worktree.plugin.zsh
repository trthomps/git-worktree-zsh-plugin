# git-worktree.plugin.zsh
# Enhanced git worktree management with bare repository support

# Configuration: Directories to share across worktrees
# These directories will be stored in the repository root and symlinked into each worktree
# Add any directories you want shared here
# Example: GWT_SHARED_DIRS=(.claude .idea .vscode)
# Can be set in .zshrc before or after this plugin loads
if [[ ! -v GWT_SHARED_DIRS ]]; then
  GWT_SHARED_DIRS=()
fi

# Configuration: Copy-on-Write mode for worktree checkout
# Uses filesystem reflinks (APFS cp -c / Linux cp --reflink) to avoid
# duplicating files across worktrees. Huge savings for repos with large/LFS files.
# Values: "auto" (detect filesystem support), "on" (force, fail if unsupported), "off"
# Can be set in .zshrc before or after this plugin loads
if [[ ! -v GWT_COW ]]; then
  GWT_COW="auto"
fi

# --- Internal helpers ---

# _gwt_repo_root - Resolve the bare repository root (parent of .git)
# Prints the path to stdout. Returns 1 if not in a git repo.
function _gwt_repo_root() {
  local git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$git_common_dir" ]]; then
    (cd "$(dirname "$git_common_dir")" && pwd)
  else
    return 1
  fi
}

# _gwt_default_branch - Detect the default branch name
# Checks origin/HEAD, then falls back to main, then master.
# Prints the branch name to stdout. Returns 1 if detection fails.
function _gwt_default_branch() {
  local branch
  branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -n "$branch" ]]; then
    echo "$branch"
    return 0
  fi

  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    return 1
  fi
}

# _gwt_ensure_fetch_refspec - Ensure `origin` has a fetch refspec
# `git clone --bare` does not set a fetch refspec by default, which means
# `git fetch origin` silently fails to update refs/remotes/origin/*. Every
# branch-existence check in this plugin depends on those tracking refs, so
# without a refspec, `gwtw <existing-remote-branch>` mistakenly falls through
# to "create new branch from origin/main" and silently creates stale state.
# If no fetch refspec is configured at all, add the standard broad one.
function _gwt_ensure_fetch_refspec() {
  local repo_root=$(_gwt_repo_root) || return 1
  local refspecs
  refspecs=$(cd "$repo_root" && git config --get-all remote.origin.fetch 2>/dev/null)
  if [[ -z "$refspecs" ]]; then
    echo "🔧 Adding missing fetch refspec to origin (bare-clone default)"
    (cd "$repo_root" && git config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*')
  fi
}

# _gwt_select_worktree - Interactive worktree selector via fzf
# Usage: _gwt_select_worktree <prompt>
# Prints the selected worktree path to stdout. Returns 1 if nothing selected or fzf unavailable.
function _gwt_select_worktree() {
  local prompt="${1:-Select worktree: }"

  if ! command -v fzf &> /dev/null; then
    return 1
  fi

  local selection
  selection=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | grep -v '\.git$' | fzf --height 40% --reverse --prompt "$prompt")

  if [[ -z "$selection" ]]; then
    return 1
  fi

  echo "$selection"
}

# _gwt_cleanup_shared_dirs - Remove shared directory symlinks from a worktree
# Usage: _gwt_cleanup_shared_dirs <worktree-path>
function _gwt_cleanup_shared_dirs() {
  local worktree_path="$1"
  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
    if [[ -z "$shared_dir" ]] || [[ "$shared_dir" == "()" ]]; then
      continue
    fi
    local symlink_path="$worktree_path/$shared_dir"
    if [[ -L "$symlink_path" ]]; then
      rm "$symlink_path"
    fi
  done
}

# _gwt_setup_shared_dirs - Set up shared directory symlinks in a worktree
# Creates shared directories in repo root and symlinks them into the worktree
# Usage: _gwt_setup_shared_dirs <worktree-path>
function _gwt_setup_shared_dirs() {
  local worktree_path="$1"

  if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
    return 1
  fi

  local repo_root=$(_gwt_repo_root) || return 1

  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
    if [[ -z "$shared_dir" ]] || [[ "$shared_dir" == "()" ]]; then
      continue
    fi

    local root_shared_path="$repo_root/$shared_dir"
    local worktree_shared_path="$worktree_path/$shared_dir"

    # Create the shared directory in repo root if it doesn't exist
    if [[ ! -e "$root_shared_path" ]]; then
      mkdir -p "$root_shared_path"
    fi

    # Remove any existing file/directory in the worktree at this location
    if [[ -e "$worktree_shared_path" ]] && [[ ! -L "$worktree_shared_path" ]]; then
      echo "  ℹ️  Removing existing $shared_dir directory in worktree"
      rm -rf "$worktree_shared_path"
    fi

    # Create symlink if it doesn't already exist
    if [[ ! -L "$worktree_shared_path" ]]; then
      ln -s "$root_shared_path" "$worktree_shared_path"
      echo "  🔗 Linked $shared_dir to shared directory"
    fi
  done
}

# _gwt_setup_zed_project_name - Initialize .zed/settings.json with project_name if missing
# Requires .zed to already exist in the worktree (e.g. via GWT_SHARED_DIRS)
# Usage: _gwt_setup_zed_project_name <worktree-path>
function _gwt_setup_zed_project_name() {
  local worktree_path="$1"
  local zed_dir="$worktree_path/.zed"

  # Only act if .zed exists (directory or symlink)
  if [[ ! -d "$zed_dir" ]]; then
    return 0
  fi

  local settings_file="$zed_dir/settings.json"
  if [[ -e "$settings_file" ]]; then
    return 0
  fi

  local repo_root=$(_gwt_repo_root) || return 1
  local project_name=$(basename "$repo_root")

  echo "  📝 Initializing .zed/settings.json with project_name: $project_name"
  cat > "$settings_file" <<EOF
{
  "project_name": "$project_name"
}
EOF
}

# _gwt_setup_tracking - Set up branch tracking to origin if applicable
# Usage: _gwt_setup_tracking <branch-name> <worktree-path>
function _gwt_setup_tracking() {
  local branch_name="$1"
  local worktree_path="$2"

  if git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
    if ! git rev-parse --abbrev-ref "$branch_name@{upstream}" &>/dev/null; then
      echo "🔗 Setting up tracking to origin/$branch_name"
      (cd "$worktree_path" && git branch --set-upstream-to=origin/$branch_name)
    fi
  fi
}

# --- Copy-on-Write helpers ---

# _gwt_cow_supported - Test whether the filesystem supports reflink copies
# Caches result per repo root for the shell session.
# Returns 0 if reflinks work, 1 otherwise.
function _gwt_cow_supported() {
  local repo_root=$(_gwt_repo_root) || return 1

  # Check session cache
  local cache_key="_gwt_cow_cache_${${repo_root//[^a-zA-Z0-9]/_}}"
  if [[ -v $cache_key ]]; then
    return ${(P)cache_key}
  fi

  local test_src=$(mktemp "$repo_root/.gwt_cow_test_XXXXXX") || return 1
  local test_dst="${test_src}.clone"
  local result=1

  echo "test" > "$test_src"
  if [[ "$OSTYPE" == darwin* ]]; then
    cp -c "$test_src" "$test_dst" 2>/dev/null && result=0
  else
    cp --reflink=always "$test_src" "$test_dst" 2>/dev/null && result=0
  fi

  rm -f "$test_src" "$test_dst"
  typeset -g "$cache_key=$result"
  return $result
}

# _gwt_find_reference_worktree - Find the best existing worktree to CoW-copy from
# Prefers the default branch worktree since most branches fork from it.
# Prints the path to stdout. Returns 1 if no suitable reference found.
function _gwt_find_reference_worktree() {
  local repo_root=$(_gwt_repo_root) || return 1

  # Prefer the default branch worktree
  local default_branch=$(_gwt_default_branch)
  if [[ -n "$default_branch" ]] && [[ -d "$repo_root/$default_branch" ]]; then
    echo "$repo_root/$default_branch"
    return 0
  fi

  # Fall back to any existing worktree (skip the bare .git dir)
  local wt_path
  local worktree_output=$(git worktree list --porcelain)
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      wt_path="${line#worktree }"
      if [[ -d "$wt_path" ]] && [[ "$wt_path" != "$repo_root" ]]; then
        echo "$wt_path"
        return 0
      fi
    fi
  done <<< "$worktree_output"

  return 1
}

# _gwt_cow_populate - CoW-copy files from reference worktree, then reconcile
# Usage: _gwt_cow_populate <new-worktree-path> <reference-worktree-path>
function _gwt_cow_populate() {
  local new_wt="$1"
  local ref_wt="$2"

  if [[ ! -d "$new_wt" ]] || [[ ! -d "$ref_wt" ]]; then
    return 1
  fi

  # Build skip set from GWT_SHARED_DIRS
  local -A skip_set
  skip_set[.git]=1
  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
    [[ -n "$shared_dir" ]] && skip_set[${shared_dir%%/*}]=1
  done

  # CoW-copy each top-level item from reference worktree
  local cp_cmd
  if [[ "$OSTYPE" == darwin* ]]; then
    cp_cmd=(cp -Rc)
  else
    cp_cmd=(cp -R --reflink=auto)
  fi

  local item name
  for item in "$ref_wt"/*(DN); do
    name=$(basename "$item")
    (( ${+skip_set[$name]} )) && continue
    "${cp_cmd[@]}" "$item" "$new_wt/$name"
  done

  # Reconcile: populate index from HEAD, then only checkout files that
  # actually differ between the two commits. A blanket `git checkout -- .`
  # would re-trigger LFS smudge filters on every file, breaking reflinks.
  local ref_commit=$(git -C "$ref_wt" rev-parse HEAD 2>/dev/null)
  local new_commit=$(git -C "$new_wt" rev-parse HEAD 2>/dev/null)

  (cd "$new_wt" && git reset) 2>/dev/null

  if [[ -n "$ref_commit" ]] && [[ -n "$new_commit" ]] && [[ "$ref_commit" != "$new_commit" ]]; then
    # Only reconcile files that differ between the two trees. Paths that exist
    # in new_commit get checked out; paths that only existed in ref_commit
    # (deletions) get removed. Doing a blanket `git checkout HEAD -- <path>`
    # fails with "pathspec did not match any file(s) known to git" for
    # deleted paths, which is how we were leaving stale files behind before.
    local to_checkout to_remove
    to_checkout=$(git diff-tree -r --name-only --no-commit-id --diff-filter=d "$ref_commit" "$new_commit" 2>/dev/null)
    to_remove=$(git diff-tree -r --name-only --no-commit-id --diff-filter=D "$ref_commit" "$new_commit" 2>/dev/null)

    if [[ -n "$to_remove" ]]; then
      echo "$to_remove" | (cd "$new_wt" && xargs rm -f)
    fi
    if [[ -n "$to_checkout" ]]; then
      echo "$to_checkout" | (cd "$new_wt" && xargs git checkout HEAD --)
    fi
  fi

  # Refresh index stat cache to match the CoW-copied files
  (cd "$new_wt" && git update-index --refresh) 2>/dev/null
}

# _gwt_add_worktree - Create a worktree, using CoW when possible
# Wraps `git worktree add` with optional CoW optimization.
# Usage: _gwt_add_worktree <git-worktree-add-args...>
# The last positional arg that looks like a path is treated as the worktree path.
function _gwt_add_worktree() {
  local repo_root=$(_gwt_repo_root) || repo_root=$(pwd)
  local use_cow=false

  # Determine if we should attempt CoW
  if [[ "$GWT_COW" == "on" ]]; then
    if ! _gwt_cow_supported; then
      echo "❌ GWT_COW=on but filesystem does not support reflinks"
      return 1
    fi
    use_cow=true
  elif [[ "$GWT_COW" == "auto" ]]; then
    _gwt_cow_supported && use_cow=true
  fi

  local ref_wt=""
  if $use_cow; then
    ref_wt=$(_gwt_find_reference_worktree)
    if [[ -z "$ref_wt" ]]; then
      use_cow=false
    fi
  fi

  if $use_cow; then
    echo "🐄 Using Copy-on-Write from $(basename "$ref_wt")"
    # Insert --no-checkout after "add" in the args
    local args=()
    local found_add=false
    for arg in "$@"; do
      args+=("$arg")
      if [[ "$found_add" == false ]] && [[ "$arg" == "add" ]]; then
        args+=(--no-checkout)
        found_add=true
      fi
    done

    # If no "add" was found, the caller passed args without "add" prefix
    # (they expect us to prepend it)
    if [[ "$found_add" == false ]]; then
      args=(add --no-checkout "$@")
    fi

    (cd "$repo_root" && git worktree "${args[@]}") || return 1

    # Determine the worktree path from the args
    # git worktree add [flags] [-b <branch>] <path> [<commit-ish>]
    local wt_path=""
    local past_add=false
    local skip_next=false
    for arg in "${args[@]}"; do
      if $skip_next; then skip_next=false; continue; fi
      [[ "$arg" == "add" ]] && past_add=true && continue
      $past_add || continue
      [[ "$arg" == --* ]] && continue
      # -b takes the next arg as branch name, skip both
      if [[ "$arg" == "-b" ]]; then skip_next=true; continue; fi
      [[ "$arg" == -* ]] && continue
      # First positional arg after add and flags is the path
      if [[ -z "$wt_path" ]]; then
        wt_path="$arg"
      fi
    done

    if [[ -n "$wt_path" ]] && [[ -d "$repo_root/$wt_path" ]]; then
      _gwt_cow_populate "$repo_root/$wt_path" "$ref_wt" || {
        echo "⚠️  CoW populate failed, falling back to normal checkout"
        # `git checkout -f HEAD` restores tracked files but leaves any
        # CoW-copied files that aren't in HEAD sitting around as untracked,
        # which blocks subsequent `git pull`. Reset + clean gets back to a
        # pristine checkout of HEAD.
        (cd "$repo_root/$wt_path" && git reset --hard HEAD && git clean -fd)
      }
    fi
  else
    (cd "$repo_root" && git worktree "$@") || return 1
  fi
}

# --- Public commands ---

# gwtc - Git Worktree Clone
# Clone a repository as bare and set up main worktree
# Usage: gwtc <repo-url> [directory-name]
function gwtc() {
  if [[ -z "$1" ]]; then
    echo "Usage: gwtc <repo-url> [directory-name]"
    return 1
  fi

  local repo_url="$1"
  local dir_name="${2:-$(basename "$repo_url" .git)}"

  echo "📦 Cloning bare repository into $dir_name/.git..."

  # Create parent directory and clone bare repo into .git subdirectory
  mkdir -p "$dir_name" || return 1
  git clone --bare "$repo_url" "$dir_name/.git" || return 1

  cd "$dir_name" || return 1

  # Configure remote to fetch all branches (bare clones don't set this up by default)
  git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

  # Bare clone puts branches under refs/heads/* which conflict with worktree branch
  # creation. Remove them so they only exist as remote tracking refs after fetch.
  git for-each-ref --format='%(refname)' refs/heads/ | while IFS= read -r ref; do
    git update-ref -d "$ref"
  done

  # Fetch to populate refs/remotes/origin/* cleanly
  echo "📡 Fetching remote refs..."
  git fetch origin || return 1

  # Get the default branch name by querying the remote
  local default_branch=$(git ls-remote --symref origin HEAD | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2}')

  # Fallback: check for common default branch names on remote refs
  if [[ -z "$default_branch" ]]; then
    if git show-ref --verify --quiet refs/remotes/origin/main; then
      default_branch="main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
      default_branch="master"
    else
      default_branch=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v 'HEAD' | head -n1 | sed 's@origin/@@')
    fi
  fi

  if [[ -z "$default_branch" ]]; then
    echo "❌ Could not determine default branch"
    return 1
  fi

  echo "🌿 Creating main worktree for branch: $default_branch"
  git worktree add --track -b "$default_branch" "$default_branch" "origin/$default_branch" || return 1

  local worktree_full_path="$(pwd)/$default_branch"
  _gwt_setup_shared_dirs "$worktree_full_path"
  _gwt_setup_zed_project_name "$worktree_full_path"

  cd "$default_branch" || return 1

  echo "✅ Repository cloned and $default_branch worktree created"
  echo "📂 Working directory: $(pwd)"
}

# gwta - Git Worktree Add
# Add a new worktree (creates branch if needed)
# Usage: gwta <branch-name> [-b] [base-branch]
function gwta() {
  if [[ -z "$1" ]]; then
    echo "Usage: gwta <branch-name> [-b] [base-branch]"
    echo "  -b: create a new branch"
    echo "Example: gwta feature/new-feature -b main"
    return 1
  fi

  local branch_name="$1"
  local repo_root=$(_gwt_repo_root)
  if [[ -z "$repo_root" ]]; then
    repo_root=$(pwd)
  fi

  _gwt_ensure_fetch_refspec

  local wt_ok=false
  if [[ "$2" == "-b" ]]; then
    local base_branch="${3:-HEAD}"
    # Fetch the latest base branch from origin before branching
    if [[ "$base_branch" != "HEAD" ]]; then
      echo "📡 Fetching latest '$base_branch' from origin..."
      (cd "$repo_root" && git fetch origin "$base_branch" 2>/dev/null)
      if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
        echo "🌱 Creating new branch '$branch_name' from origin/$base_branch"
        _gwt_add_worktree add -b "$branch_name" "$branch_name" "origin/$base_branch" && wt_ok=true
      else
        echo "⚠️  Remote branch 'origin/$base_branch' not found, using local '$base_branch'"
        _gwt_add_worktree add -b "$branch_name" "$branch_name" "$base_branch" && wt_ok=true
      fi
    else
      echo "🌱 Creating new branch '$branch_name' from $base_branch"
      _gwt_add_worktree add -b "$branch_name" "$branch_name" "$base_branch" && wt_ok=true
    fi
  elif git show-ref --verify --quiet "refs/heads/$branch_name"; then
    echo "🌿 Checking out existing branch '$branch_name'"
    _gwt_add_worktree add "$branch_name" "$branch_name" && wt_ok=true
    $wt_ok && _gwt_setup_tracking "$branch_name" "$repo_root/$branch_name"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
    echo "🌿 Branch '$branch_name' exists on remote, creating worktree with tracking..."
    _gwt_add_worktree add --track -b "$branch_name" "$branch_name" "origin/$branch_name" && wt_ok=true
  else
    echo "❌ Branch '$branch_name' doesn't exist. Use 'gwta $branch_name -b' to create it."
    return 1
  fi

  if $wt_ok; then
    echo "✅ Worktree created at: $repo_root/$branch_name"
    _gwt_setup_shared_dirs "$repo_root/$branch_name"
    _gwt_setup_zed_project_name "$repo_root/$branch_name"
  fi
}

# gwtl - Git Worktree List
# List all worktrees with enhanced formatting
function gwtl() {
  git worktree list
}

# gwtr - Git Worktree Remove
# Remove a worktree
# Usage: gwtr [path]
# If no path provided and fzf is available, opens interactive selector
function gwtr() {
  local worktree_path="$1"

  if [[ -z "$worktree_path" ]]; then
    worktree_path=$(_gwt_select_worktree "Select worktree to remove: ")
    if [[ -z "$worktree_path" ]]; then
      echo "Usage: gwtr <worktree-path>"
      echo "Available worktrees:"
      git worktree list
      return 1
    fi
  fi

  _gwt_cleanup_shared_dirs "$worktree_path"
  echo "🗑️  Removing worktree: $worktree_path"
  git worktree remove "$worktree_path"
}

# gwtrm - Git Worktree Remove with force
# Force remove a worktree (even with uncommitted changes)
# Usage: gwtrm [path]
# If no path provided and fzf is available, opens interactive selector
function gwtrm() {
  local worktree_path="$1"

  if [[ -z "$worktree_path" ]]; then
    worktree_path=$(_gwt_select_worktree "Select worktree to force remove: ")
    if [[ -z "$worktree_path" ]]; then
      echo "Usage: gwtrm <worktree-path>"
      return 1
    fi
  fi

  _gwt_cleanup_shared_dirs "$worktree_path"
  echo "⚠️  Force removing worktree: $worktree_path"
  git worktree remove --force "$worktree_path"
}

# gwtp - Git Worktree Prune
# Clean up worktree information for deleted directories
function gwtp() {
  echo "🧹 Pruning stale worktree references..."
  git worktree prune -v
}

# gwtcd - Git Worktree CD
# Fuzzy find and cd into a worktree
function gwtcd() {
  local worktree_path
  worktree_path=$(_gwt_select_worktree "Select worktree: ")

  if [[ -z "$worktree_path" ]]; then
    echo "❌ fzf is required for gwtcd. Install it or use 'cd' manually."
    echo "Available worktrees:"
    git worktree list
    return 1
  fi

  cd "$worktree_path"
}

# gwtmv - Git Worktree Move
# Move a worktree to a new location
# Usage: gwtmv <source> <destination>
function gwtmv() {
  if [[ -z "$1" ]] || [[ -z "$2" ]]; then
    echo "Usage: gwtmv <source> <destination>"
    return 1
  fi

  echo "📦 Moving worktree from $1 to $2"
  git worktree move "$1" "$2"
}

# gwtlock - Git Worktree Lock
# Lock a worktree to prevent it from being pruned
# Usage: gwtlock [path] [reason]
# If no path provided and fzf is available, opens interactive selector
function gwtlock() {
  local worktree_path="$1"
  local reason="${2:-locked by user}"

  if [[ -z "$worktree_path" ]]; then
    worktree_path=$(_gwt_select_worktree "Select worktree to lock: ")
    if [[ -z "$worktree_path" ]]; then
      echo "Usage: gwtlock <worktree-path> [reason]"
      return 1
    fi
  fi

  echo "🔒 Locking worktree: $worktree_path"
  git worktree lock "$worktree_path" --reason "$reason"
}

# gwtunlock - Git Worktree Unlock
# Unlock a worktree
# Usage: gwtunlock [path]
# If no path provided and fzf is available, opens interactive selector
function gwtunlock() {
  local worktree_path="$1"

  if [[ -z "$worktree_path" ]]; then
    worktree_path=$(_gwt_select_worktree "Select worktree to unlock: ")
    if [[ -z "$worktree_path" ]]; then
      echo "Usage: gwtunlock <worktree-path>"
      return 1
    fi
  fi

  echo "🔓 Unlocking worktree: $worktree_path"
  git worktree unlock "$worktree_path"
}

# gwtw - Git Worktree Work
# Quick switch or create worktree for a branch (designed for Linear workflow)
# Usage: gwtw [branch-name] [base-branch]
# If no branch provided and fzf is available, opens interactive selector
# If worktree exists, cd into it. If not, create it and cd into it.
function gwtw() {
  local branch_name="$1"
  local base_branch="$2"

  if [[ -z "$branch_name" ]]; then
    if command -v fzf &> /dev/null; then
      # Get list of local and remote branches
      local branches=$(
        {
          git for-each-ref --format='%(refname:short)' refs/heads/ | sed 's/^/  /'
          git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v '/HEAD$' | sed 's@^origin/@@' | sed 's/^/  origin\/@/'
        } | sort -u
      )

      local selection=$(echo "$branches" | fzf --height 40% --reverse --prompt "Select or type branch name: " --print-query | tail -n1)

      if [[ -z "$selection" ]]; then
        echo "No branch selected"
        return 1
      fi

      branch_name=$(echo "$selection" | sed 's/^  origin\/@//' | sed 's/^  //')
    else
      echo "Usage: gwtw <branch-name> [base-branch]"
      echo "Example: gwtw travis/plat-934-non-deterministic-behavior"
      return 1
    fi
  fi

  local repo_root=$(_gwt_repo_root)
  if [[ -z "$repo_root" ]]; then
    repo_root=$(pwd)
  fi

  # Check if worktree directory already exists at repo root
  if [[ -d "$repo_root/$branch_name" ]]; then
    echo "📂 Worktree '$branch_name' already exists, switching to it..."
    cd "$repo_root/$branch_name"
    return 0
  fi

  # Fetch latest refs from origin so branch existence checks are current
  _gwt_ensure_fetch_refspec
  echo "📡 Fetching from origin..."
  (cd "$repo_root" && git fetch origin 2>/dev/null)

  # Check if branch exists locally or remotely
  local wt_ok=false
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    echo "🌿 Branch '$branch_name' exists, creating worktree..."
    _gwt_add_worktree add "$branch_name" "$branch_name" && wt_ok=true
    $wt_ok && _gwt_setup_tracking "$branch_name" "$repo_root/$branch_name"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
    echo "🌿 Branch '$branch_name' exists on remote, creating worktree with tracking..."
    _gwt_add_worktree add --track -b "$branch_name" "$branch_name" "origin/$branch_name" && wt_ok=true
  else
    # Auto-detect default branch if base not specified (only needed for new branches)
    if [[ -z "$base_branch" ]]; then
      base_branch=$(_gwt_default_branch)
      if [[ -z "$base_branch" ]]; then
        echo "❌ Could not detect default branch. Please specify: gwtw <branch> <base-branch>"
        return 1
      fi
    fi

    echo "🌱 Creating new branch '$branch_name' from origin/$base_branch..."
    if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
      _gwt_add_worktree add -b "$branch_name" "$branch_name" "origin/$base_branch" && wt_ok=true
    else
      echo "⚠️  Remote branch 'origin/$base_branch' not found, using local '$base_branch'"
      _gwt_add_worktree add -b "$branch_name" "$branch_name" "$base_branch" && wt_ok=true
    fi
  fi

  if $wt_ok; then
    echo "✅ Worktree ready at: $repo_root/$branch_name"
    _gwt_setup_shared_dirs "$repo_root/$branch_name"
    _gwt_setup_zed_project_name "$repo_root/$branch_name"
    cd "$repo_root/$branch_name"
  fi
}

# gwtu - Git Worktree Update
# Fetch latest from origin and rebase the current branch onto the default branch
# Usage: gwtu [base-branch]
# Auto-detects the default branch if not specified
function gwtu() {
  local base_branch="$1"
  local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

  if [[ -z "$current_branch" ]]; then
    echo "❌ Not on a branch (detached HEAD)"
    return 1
  fi

  if [[ -z "$base_branch" ]]; then
    base_branch=$(_gwt_default_branch)
    if [[ -z "$base_branch" ]]; then
      echo "❌ Could not detect default branch. Please specify: gwtu <base-branch>"
      return 1
    fi
  fi

  _gwt_ensure_fetch_refspec

  echo "📡 Fetching latest '$base_branch' from origin..."
  git fetch origin "$base_branch" || return 1

  echo "🔄 Rebasing '$current_branch' onto origin/$base_branch..."
  git rebase "origin/$base_branch"
}

# gwtclean - Git Worktree Clean
# Clean up worktrees for branches that have been merged
# Usage: gwtclean [target-branch] [-f]
# Auto-detects the default branch if not specified
# -f flag will skip confirmation and automatically clean up merged branches
function gwtclean() {
  local target_branch=""
  local force=0

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=1
        shift
        ;;
      *)
        target_branch="$1"
        shift
        ;;
    esac
  done

  local repo_root=$(_gwt_repo_root)
  if [[ -z "$repo_root" ]]; then
    echo "❌ Not in a git repository"
    return 1
  fi

  # Auto-detect target branch if not specified
  if [[ -z "$target_branch" ]]; then
    target_branch=$(_gwt_default_branch)
    if [[ -z "$target_branch" ]]; then
      echo "❌ Could not auto-detect default branch. Please specify: gwtclean <branch-name>"
      return 1
    fi
    echo "🎯 Auto-detected target branch: $target_branch"
  fi

  # Verify target branch exists
  if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
    echo "❌ Target branch '$target_branch' does not exist"
    return 1
  fi

  echo "🔍 Finding branches merged into '$target_branch'..."

  # Get list of traditionally merged branches (excluding the target branch itself)
  # Note: git branch output uses prefixes: * (current), + (checked out in worktree), space (regular)
  local traditionally_merged=$(git branch --merged "$target_branch" | grep -v "^\*" | sed 's/^[*+ ] //' | grep -v "^$target_branch$")

  # Get all local branches (excluding current and target)
  local all_branches=$(git branch | grep -v "^\*" | sed 's/^[*+ ] //' | grep -v "^$target_branch$")

  # Arrays to hold different categories of branches
  local merged_branches=()
  local squash_merged_branches=()
  local remote_deleted_branches=()
  local unpushed_remote_deleted_branches=()

  # Classify traditionally merged branches
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$target_branch" ]] && continue
    merged_branches+=("$branch")
  done <<< "$traditionally_merged"

  # Check remaining branches for squash merges and remote deletion
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$target_branch" ]] && continue

    # Skip if already in merged_branches
    if [[ " ${merged_branches[@]} " =~ " ${branch} " ]]; then
      continue
    fi

    local is_squash_merged=false
    local remote_exists=false
    local has_upstream=false

    # Check if branch name appears in recent merge commits (squash merge detection)
    local escaped_branch=$(printf '%s\n' "$branch" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if git log "$target_branch" --oneline --grep="$escaped_branch" -i --all-match -E -n 20 | grep -qiE "(merge|squash)"; then
      is_squash_merged=true
    fi

    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      remote_exists=true
    fi

    if git rev-parse --abbrev-ref "$branch@{upstream}" &>/dev/null; then
      has_upstream=true
    fi

    if [[ "$is_squash_merged" == true ]]; then
      squash_merged_branches+=("$branch")
    elif [[ "$has_upstream" == true ]] && [[ "$remote_exists" == false ]]; then
      remote_deleted_branches+=("$branch")
    elif [[ "$has_upstream" == false ]] && [[ "$remote_exists" == false ]]; then
      unpushed_remote_deleted_branches+=("$branch")
    fi
  done <<< "$all_branches"

  # Combine all detected merged branches for processing
  local all_detected_merged=("${merged_branches[@]}" "${squash_merged_branches[@]}" "${remote_deleted_branches[@]}")

  if [[ ${#all_detected_merged[@]} -eq 0 ]] && [[ ${#unpushed_remote_deleted_branches[@]} -eq 0 ]]; then
    echo "✨ No merged branches found"
    return 0
  fi

  # Display findings
  if [[ ${#merged_branches[@]} -gt 0 ]]; then
    echo ""
    echo "📋 Traditionally merged branches:"
    printf '  • %s\n' "${merged_branches[@]}"
  fi

  if [[ ${#squash_merged_branches[@]} -gt 0 ]]; then
    echo ""
    echo "🔀 Squash-merged branches (detected from commit messages):"
    printf '  • %s\n' "${squash_merged_branches[@]}"
  fi

  if [[ ${#remote_deleted_branches[@]} -gt 0 ]]; then
    echo ""
    echo "🌐 Branches with deleted remotes (likely merged):"
    printf '  • %s\n' "${remote_deleted_branches[@]}"
  fi

  if [[ ${#unpushed_remote_deleted_branches[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  Unpushed local branches (need confirmation):"
    printf '  • %s\n' "${unpushed_remote_deleted_branches[@]}"
  fi

  echo ""

  # Find worktrees for detected merged branches
  local worktrees_to_remove=()
  local branches_to_delete=()
  local branches_without_worktrees=()

  for branch in "${all_detected_merged[@]}"; do
    [[ -z "$branch" ]] && continue

    local worktree_path="$repo_root/$branch"
    if [[ -d "$worktree_path" ]]; then
      if git worktree list --porcelain | grep -q "^worktree $worktree_path$"; then
        worktrees_to_remove+=("$worktree_path")
        branches_to_delete+=("$branch")
      else
        branches_without_worktrees+=("$branch")
      fi
    else
      branches_without_worktrees+=("$branch")
    fi
  done

  # Handle unpushed branches separately with confirmation
  local unpushed_to_delete=()
  if [[ ${#unpushed_remote_deleted_branches[@]} -gt 0 ]]; then
    if [[ $force -eq 0 ]]; then
      echo "⚠️  The following branches were never pushed to remote."
      echo "   Review each one to decide whether to delete it:"
      echo ""

      for branch in "${unpushed_remote_deleted_branches[@]}"; do
        echo -n "Delete '$branch'? [y/N] "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          unpushed_to_delete+=("$branch")
        fi
      done

      echo ""
    else
      echo "⚠️  Force mode: including unpushed branches in cleanup"
      unpushed_to_delete=("${unpushed_remote_deleted_branches[@]}")
    fi

    for branch in "${unpushed_to_delete[@]}"; do
      local worktree_path="$repo_root/$branch"
      if [[ -d "$worktree_path" ]] && git worktree list --porcelain | grep -q "^worktree $worktree_path$"; then
        worktrees_to_remove+=("$worktree_path")
        branches_to_delete+=("$branch")
      else
        branches_without_worktrees+=("$branch")
      fi
    done
  fi

  # Check if there's anything to clean up
  if [[ ${#worktrees_to_remove[@]} -eq 0 ]] && [[ ${#branches_without_worktrees[@]} -eq 0 ]]; then
    echo "✨ No branches to clean up"
    return 0
  fi

  # Display what will be removed
  if [[ ${#worktrees_to_remove[@]} -gt 0 ]]; then
    echo "🗑️  Worktrees to remove:"
    for i in {1..${#worktrees_to_remove[@]}}; do
      echo "  • ${branches_to_delete[$i]} → ${worktrees_to_remove[$i]}"
    done
    echo ""
  fi

  if [[ ${#branches_without_worktrees[@]} -gt 0 ]]; then
    echo "🗑️  Branches to delete (no worktrees):"
    printf '  • %s\n' "${branches_without_worktrees[@]}"
    echo ""
  fi

  # Confirm unless force flag is set
  if [[ $force -eq 0 ]]; then
    local total_count=$((${#worktrees_to_remove[@]} + ${#branches_without_worktrees[@]}))
    echo -n "Remove $total_count branch(es) and their worktrees? [y/N] "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "Cancelled"
      return 0
    fi
  fi

  # Remove worktrees and delete branches
  local removed_count=0

  for i in {1..${#worktrees_to_remove[@]}}; do
    local worktree_path="${worktrees_to_remove[$i]}"
    local branch="${branches_to_delete[$i]}"

    echo "🗑️  Removing worktree: $worktree_path"
    _gwt_cleanup_shared_dirs "$worktree_path"

    if git worktree remove "$worktree_path" 2>/dev/null; then
      echo "🗑️  Deleting branch: $branch"
      git branch -D "$branch" 2>/dev/null && ((removed_count++))
    fi
  done

  for branch in "${branches_without_worktrees[@]}"; do
    echo "🗑️  Deleting branch: $branch"
    git branch -D "$branch" 2>/dev/null && ((removed_count++))
  done

  echo ""
  echo "✅ Cleanup complete - removed $removed_count branch(es) and worktree(s)"
}

# Aliases for shorter commands
alias gwt="git worktree"
alias gwtls="gwtl"
alias gwtrp="gwtp"
alias gwtcl="gwtclean"
alias gwtup="gwtu"
