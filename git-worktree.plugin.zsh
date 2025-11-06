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

  # Find the repository root
  local repo_root=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$repo_root" ]]; then
    repo_root=$(cd "$(dirname "$repo_root")" && pwd)
  else
    echo "❌ Not in a git repository"
    return 1
  fi

  # Auto-detect target branch if not specified
  if [[ -z "$target_branch" ]]; then
    # Try to get the default branch from remote
    target_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

    # Fallback: check for common default branch names
    if [[ -z "$target_branch" ]]; then
      if git show-ref --verify --quiet refs/heads/main; then
        target_branch="main"
      elif git show-ref --verify --quiet refs/heads/master; then
        target_branch="master"
      else
        echo "❌ Could not auto-detect default branch. Please specify: gwtclean <branch-name>"
        return 1
      fi
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
  local traditionally_merged=$(git branch --merged "$target_branch" | grep -v "^\*" | grep -v "^  $target_branch$" | sed 's/^[* ] //')

  # Get all local branches (excluding current and target)
  local all_branches=$(git branch | grep -v "^\*" | grep -v "^  $target_branch$" | sed 's/^[* ] //')

  # Arrays to hold different categories of branches
  local merged_branches=()
  local squash_merged_branches=()
  local remote_deleted_branches=()
  local unpushed_remote_deleted_branches=()

  # Classify traditionally merged branches
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    merged_branches+=("$branch")
  done <<< "$traditionally_merged"

  # Check remaining branches for squash merges and remote deletion
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    # Skip if already in merged_branches
    if [[ " ${merged_branches[@]} " =~ " ${branch} " ]]; then
      continue
    fi

    local is_squash_merged=false
    local remote_exists=false
    local has_upstream=false

    # Check if branch name appears in recent merge commits (squash merge detection)
    # Look for patterns like "Merge pull request" or "Merge branch" with the branch name
    if git log "$target_branch" --oneline --grep="$branch" -i --all-match -E -n 20 | grep -qiE "(merge|squash)"; then
      is_squash_merged=true
    fi

    # Check if branch exists on remote
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      remote_exists=true
    fi

    # Check if branch has upstream tracking
    if git rev-parse --abbrev-ref "$branch@{upstream}" &>/dev/null; then
      has_upstream=true
    fi

    # Categorize the branch
    if [[ "$is_squash_merged" == true ]]; then
      squash_merged_branches+=("$branch")
    elif [[ "$has_upstream" == true ]] && [[ "$remote_exists" == false ]]; then
      # Branch was tracking remote but remote is deleted - likely merged
      remote_deleted_branches+=("$branch")
    elif [[ "$has_upstream" == false ]] && [[ "$remote_exists" == false ]]; then
      # Branch never pushed and remote doesn't exist - needs confirmation
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

    # Check if worktree exists for this branch
    local worktree_path="$repo_root/$branch"
    if [[ -d "$worktree_path" ]]; then
      # Verify it's actually a worktree
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
      echo "⚠️  The following branches were never pushed to remote:"
      printf '  • %s\n' "${unpushed_remote_deleted_branches[@]}"
      echo ""
      echo -n "Include these unpushed branches in cleanup? [y/N] "
      read -r response
      if [[ "$response" =~ ^[Yy]$ ]]; then
        unpushed_to_delete=("${unpushed_remote_deleted_branches[@]}")
      fi
    else
      # In force mode, include unpushed branches with a warning
      echo "⚠️  Force mode: including unpushed branches in cleanup"
      unpushed_to_delete=("${unpushed_remote_deleted_branches[@]}")
    fi

    # Add unpushed branches to the appropriate lists
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

    # Remove shared directory symlinks
    for shared_dir in "${GWT_SHARED_DIRS[@]}"; do
      local symlink_path="$worktree_path/$shared_dir"
      if [[ -L "$symlink_path" ]]; then
        rm "$symlink_path"
      fi
    done

    # Remove worktree
    if git worktree remove "$worktree_path" 2>/dev/null; then
      # Delete branch
      echo "🗑️  Deleting branch: $branch"
      git branch -d "$branch" 2>/dev/null && ((removed_count++))
    fi
  done

  # Delete branches without worktrees
  for branch in "${branches_without_worktrees[@]}"; do
    echo "🗑️  Deleting branch: $branch"
    git branch -d "$branch" 2>/dev/null && ((removed_count++))
  done

  echo ""
  echo "✅ Cleanup complete - removed $removed_count branch(es) and worktree(s)"
}

# Aliases for shorter commands
alias gwt="git worktree"
alias gwtls="gwtl"
alias gwtrp="gwtp"
alias gwtcl="gwtclean"
