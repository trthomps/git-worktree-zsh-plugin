# git-worktree.plugin.zsh
# Enhanced git worktree management with bare repository support

# Configuration: Directories to share across worktrees
# These directories will be stored in the repository root and symlinked into each worktree
# Add any directories you want shared here
# Example: GWT_SHARED_DIRS=(.claude .idea .vscode)
# Can be set in .zshrc before or after this plugin loads
: ${GWT_SHARED_DIRS:=()}

# _gwt_setup_shared_dirs - Internal function to set up shared directory symlinks
# Creates shared directories in repo root and symlinks them into the worktree
# Usage: _gwt_setup_shared_dirs <worktree-path>
function _gwt_setup_shared_dirs() {
  local worktree_path="$1"

  if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
    return 1
  fi

  # Find the repository root (where .git is)
  local repo_root=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$repo_root" ]]; then
    repo_root=$(cd "$(dirname "$repo_root")" && pwd)
  else
    return 1
  fi

  # Process each shared directory
  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
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

  # Get the default branch name by querying the remote
  # This works in a bare repository
  local default_branch=$(git ls-remote --symref origin HEAD | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2}')

  # Fallback: check for common default branch names
  if [[ -z "$default_branch" ]]; then
    if git show-ref --verify --quiet refs/remotes/origin/main; then
      default_branch="main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
      default_branch="master"
    else
      # Last resort: get the first branch from refs
      default_branch=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v 'HEAD' | head -n1 | sed 's@origin/@@')
    fi
  fi

  if [[ -z "$default_branch" ]]; then
    echo "❌ Could not determine default branch"
    return 1
  fi

  echo "🌿 Creating main worktree for branch: $default_branch"
  git worktree add "$default_branch" "$default_branch" || return 1

  # Set up shared directories before changing into worktree
  local worktree_full_path="$(pwd)/$default_branch"
  _gwt_setup_shared_dirs "$worktree_full_path"

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
  local create_branch=""
  local base_branch="HEAD"

  # Find the repository root (where .git is)
  local repo_root=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$repo_root" ]]; then
    repo_root=$(cd "$(dirname "$repo_root")" && pwd)
  else
    repo_root=$(pwd)
  fi

  # Check for -b flag
  if [[ "$2" == "-b" ]]; then
    create_branch="-b"
    base_branch="${3:-HEAD}"
    echo "🌱 Creating new branch '$branch_name' from $base_branch"
    (cd "$repo_root" && git worktree add $create_branch "$branch_name" "$base_branch")
  elif git show-ref --verify --quiet "refs/heads/$branch_name"; then
    echo "🌿 Checking out existing branch '$branch_name'"
    (cd "$repo_root" && git worktree add "$branch_name" "$branch_name")
  else
    echo "❌ Branch '$branch_name' doesn't exist. Use 'gwta $branch_name -b' to create it."
    return 1
  fi

  if [[ $? -eq 0 ]]; then
    echo "✅ Worktree created at: $repo_root/$branch_name"
    _gwt_setup_shared_dirs "$repo_root/$branch_name"
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
    if command -v fzf &> /dev/null; then
      # Get list of worktrees, skip the bare repo entry
      worktree_path=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | grep -v '\.git$' | fzf --height 40% --reverse --prompt "Select worktree to remove: ")

      if [[ -z "$worktree_path" ]]; then
        echo "No worktree selected"
        return 1
      fi
    else
      echo "Usage: gwtr <worktree-path>"
      echo "Available worktrees:"
      git worktree list
      return 1
    fi
  fi

  # Remove shared directory symlinks before removing worktree
  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
    local symlink_path="$worktree_path/$shared_dir"
    if [[ -L "$symlink_path" ]]; then
      rm "$symlink_path"
    fi
  done

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
    if command -v fzf &> /dev/null; then
      # Get list of worktrees, skip the bare repo entry
      worktree_path=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | grep -v '\.git$' | fzf --height 40% --reverse --prompt "Select worktree to force remove: ")

      if [[ -z "$worktree_path" ]]; then
        echo "No worktree selected"
        return 1
      fi
    else
      echo "Usage: gwtrm <worktree-path>"
      return 1
    fi
  fi

  # Remove shared directory symlinks before removing worktree
  for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
    local symlink_path="$worktree_path/$shared_dir"
    if [[ -L "$symlink_path" ]]; then
      rm "$symlink_path"
    fi
  done

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

  # Get list of worktrees, skip the header and bare repo entry
  worktree_path=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | fzf --height 40% --reverse --prompt "Select worktree: ")

  if [[ -n "$worktree_path" ]]; then
    cd "$worktree_path"
  fi
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
    if command -v fzf &> /dev/null; then
      # Get list of worktrees, skip the bare repo entry
      worktree_path=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | grep -v '\.git$' | fzf --height 40% --reverse --prompt "Select worktree to lock: ")

      if [[ -z "$worktree_path" ]]; then
        echo "No worktree selected"
        return 1
      fi
    else
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
    if command -v fzf &> /dev/null; then
      # Get list of worktrees, skip the bare repo entry
      worktree_path=$(git worktree list --porcelain | grep "worktree " | sed 's/worktree //' | grep -v '\.git$' | fzf --height 40% --reverse --prompt "Select worktree to unlock: ")

      if [[ -z "$worktree_path" ]]; then
        echo "No worktree selected"
        return 1
      fi
    else
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
  local base_branch="${2:-main}"

  if [[ -z "$branch_name" ]]; then
    if command -v fzf &> /dev/null; then
      # Get list of local and remote branches
      local branches=$(
        {
          # Local branches
          git for-each-ref --format='%(refname:short)' refs/heads/ | sed 's/^/  /'
          # Remote branches (exclude HEAD)
          git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v '/HEAD$' | sed 's@^origin/@@' | sed 's/^/  origin\/@/'
        } | sort -u
      )

      local selection=$(echo "$branches" | fzf --height 40% --reverse --prompt "Select or type branch name: " --print-query | tail -n1)

      if [[ -z "$selection" ]]; then
        echo "No branch selected"
        return 1
      fi

      # Strip the "origin/" prefix if present
      branch_name=$(echo "$selection" | sed 's/^  origin\///' | sed 's/^  //')
    else
      echo "Usage: gwtw <branch-name> [base-branch]"
      echo "Example: gwtw travis/plat-934-non-deterministic-behavior"
      return 1
    fi
  fi

  # Find the repository root (where .git is)
  local repo_root=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$repo_root" ]]; then
    repo_root=$(cd "$(dirname "$repo_root")" && pwd)
  else
    repo_root=$(pwd)
  fi

  # Check if worktree directory already exists at repo root
  if [[ -d "$repo_root/$branch_name" ]]; then
    echo "📂 Worktree '$branch_name' already exists, switching to it..."
    cd "$repo_root/$branch_name"
    return 0
  fi

  # Check if branch exists remotely or locally
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    echo "🌿 Branch '$branch_name' exists, creating worktree..."
    (cd "$repo_root" && git worktree add "$branch_name" "$branch_name")
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
    echo "🌿 Branch '$branch_name' exists on remote, creating worktree..."
    (cd "$repo_root" && git worktree add "$branch_name" "$branch_name")
  else
    echo "🌱 Creating new branch '$branch_name' from $base_branch..."
    (cd "$repo_root" && git worktree add -b "$branch_name" "$branch_name" "$base_branch")
  fi

  if [[ $? -eq 0 ]]; then
    echo "✅ Worktree ready at: $repo_root/$branch_name"
    _gwt_setup_shared_dirs "$repo_root/$branch_name"
    cd "$repo_root/$branch_name"
  fi
}

# Aliases for shorter commands
alias gwt="git worktree"
alias gwtls="gwtl"
alias gwtrp="gwtp"
