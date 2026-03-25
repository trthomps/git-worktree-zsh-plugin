# Git Worktree Plugin for Oh-My-Zsh

Enhanced git worktree management with bare repository support. This plugin provides convenient commands for working with git worktrees, making it easy to work on multiple branches simultaneously.

## What are Git Worktrees?

Git worktrees allow you to have multiple working directories attached to the same repository. This is particularly useful when you need to work on multiple branches at the same time without constantly switching contexts.

## Workflow Examples

![Demo](https://github.com/trthomps/git-worktree-zsh-plugin/releases/download/assets/demo.gif)

### Starting a new project

```bash
# Clone repository with worktree setup
gwtc https://github.com/user/repo.git

# You're now in the main/master worktree
# Create a new feature branch
gwtw feature/awesome-feature

# Work on your feature...
# Switch back to main
gwtw main
```

### Working on multiple branches

```bash
# Create worktree for bug fix
gwtw bugfix/issue-123 main

# In another terminal, work on a feature
gwtw feature/new-thing main

# List all your worktrees
gwtl

# Jump between them with fuzzy finder
gwtcd
```

### Cleaning up

```bash
# Remove finished worktrees
gwtr feature/completed-feature

# Clean up merged branches and their worktrees
gwtclean

# Clean up references to manually deleted worktrees
gwtp
```

## Benefits of Using Worktrees

1. **No context switching**: Keep your build artifacts, node_modules, and IDE state intact per branch
2. **Parallel work**: Run tests on one branch while developing on another
3. **Easy comparison**: Have two branches open side-by-side for easy comparison
4. **Cleaner workflow**: No need to stash changes when switching branches
5. **Disk-efficient**: Copy-on-Write support means new worktrees share storage with existing ones — critical for large repos with LFS files


## Installation

### Oh-My-Zsh

1. Clone this repository into your Oh-My-Zsh custom plugins directory:

```bash
git clone https://github.com/trthomps/git-worktree-zsh-plugin.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/git-worktree
```

2. Add `git-worktree` to your plugins array in `~/.zshrc`:

```bash
plugins=(... git-worktree)
```

3. Restart your terminal or run:

```bash
source ~/.zshrc
```

### Optional: Install fzf

For enhanced interactive selection, install [fzf](https://github.com/junegunn/fzf):

```bash
# macOS
brew install fzf

# Linux
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install
```

Many commands support interactive selection with fzf when no arguments are provided. Without fzf, you'll need to provide arguments manually.

## Keeping the Plugin Updated

To automatically update this plugin along with Oh-My-Zsh itself, consider using [OhMyZsh-full-autoupdate](https://github.com/Pilaton/OhMyZsh-full-autoupdate). This tool extends Oh-My-Zsh's built-in update mechanism to also update all custom plugins and themes automatically.

Installation is simple - just add it as another custom plugin, and it will handle updates for all your custom plugins including this one.

## Configuration

### Shared Directories

You can configure directories to be shared across all worktrees. These directories will be stored in the repository root (next to `.git`) and symlinked into each worktree. This is useful for IDE configurations, build caches, or any files you want to keep synchronized across branches.

**Setup:**

Add the following to your `~/.zshrc` before loading the plugin:

```bash
# Example: Share IDE configs and build directories
GWT_SHARED_DIRS=(.claude .idea .vscode node_modules)

plugins=(... git-worktree)
```

**How it works:**

1. When you create a worktree (using `gwtc`, `gwta`, or `gwtw`), the plugin automatically:
   - Creates the shared directories in the repository root if they don't exist
   - Creates symlinks in the new worktree pointing to the shared directories

2. When you remove a worktree (using `gwtr` or `gwtrm`), the symlinks are cleaned up automatically

**Example structure:**

```
my-repo/
├── .git/              (bare repository)
├── .claude/           (shared across all worktrees)
├── .idea/             (shared across all worktrees)
├── main/              (worktree)
│   ├── .claude -> ../.claude
│   └── .idea -> ../.idea
└── feature-branch/    (worktree)
    ├── .claude -> ../.claude
    └── .idea -> ../.idea
```

**Benefits:**

- IDE settings and configurations stay consistent across branches
- Build caches (`node_modules`, `.gradle`, etc.) are shared, saving disk space
- Claude Code and other tool configurations don't need to be reconfigured per branch

### Copy-on-Write (CoW)

For large repositories — especially those with Git LFS files — each worktree normally duplicates every file on disk. With CoW enabled, new worktrees use filesystem reflinks to share storage with an existing worktree. Files only consume additional disk space when they are actually modified.

This works on APFS (macOS), btrfs, and XFS (Linux) filesystems.

**Setup:**

Add the following to your `~/.zshrc` before loading the plugin:

```bash
# "auto" (default) - detect filesystem support and use if available
# "on"  - require reflinks, fail if unsupported
# "off" - disable, always do a full checkout
GWT_COW="auto"

plugins=(... git-worktree)
```

**How it works:**

1. When creating a worktree (via `gwta` or `gwtw`), the plugin tests whether the filesystem supports reflinks
2. If supported, it finds the best reference worktree (prefers the default branch) and creates the new worktree with `--no-checkout`
3. Files are CoW-copied from the reference worktree using `cp -c` (macOS) or `cp --reflink=auto` (Linux)
4. `git checkout` reconciles any files that differ between branches — identical files remain as zero-cost reflink clones

**Note:** `gwtc` (initial clone) always does a normal checkout since there is no reference worktree to copy from.

### Zed Editor Support

When `.zed` is included in `GWT_SHARED_DIRS`, the plugin automatically initializes `.zed/settings.json` with a `project_name` matching the repository name. This ensures Zed displays the repo name in its UI instead of the worktree branch directory name.

```bash
GWT_SHARED_DIRS=(.zed .claude .idea)
```

The `project_name` is only written when `.zed/settings.json` does not already exist, so your custom settings are never overwritten.

## Commands

### `gwtc` - Git Worktree Clone

Clone a repository as a bare repository and set up the main worktree. This is the recommended way to start using worktrees with a new repository.

**Usage:**
```bash
gwtc <repo-url> [directory-name]
```

**Examples:**
```bash
# Clone and create worktree in directory named after repo
gwtc https://github.com/user/repo.git

# Clone and create worktree in custom directory
gwtc https://github.com/user/repo.git my-project
```

**What it does:**
- Clones the repository as bare into `directory-name/.git`
- Automatically detects the default branch (main/master)
- Creates a worktree for the default branch
- Changes to the new worktree directory

---

### `gwta` - Git Worktree Add

Add a new worktree for an existing or new branch.

**Usage:**
```bash
gwta <branch-name> [-b] [base-branch]
```

**Options:**
- `-b`: Create a new branch

**Examples:**
```bash
# Create worktree for existing branch
gwta feature/new-feature

# Create new branch and worktree from main (fetches latest from origin first)
gwta feature/new-feature -b main

# Create new branch and worktree from current HEAD
gwta bugfix/issue-123 -b
```

---

### `gwtw` - Git Worktree Work

Quick switch or create worktree for a branch. This is a smart command that handles multiple scenarios automatically.

**Usage:**
```bash
gwtw [branch-name] [base-branch]
```

**Examples:**
```bash
# Switch to existing worktree or create if doesn't exist
gwtw travis/plat-934-feature

# Create from specific base branch
gwtw feature/new-thing main

# Interactive branch selection (requires fzf)
gwtw
```

**What it does:**
- If worktree exists: switches to it
- If branch exists locally: creates worktree and checks it out
- If branch exists on remote: creates worktree and tracks remote branch
- If branch doesn't exist: creates new branch from base-branch (auto-detects main/master)
- Fetches from origin before checking branch existence so remote refs are always current

**Note:** If no branch is provided and fzf is installed, an interactive branch selector will appear showing both local and remote branches. You can also type a new branch name in fzf to create it.

---

### `gwtl` - Git Worktree List

List all worktrees with their paths and branches.

**Usage:**
```bash
gwtl
```

**Example output:**
```
/path/to/repo/.git         (bare)
/path/to/repo/main         abc1234 [main]
/path/to/repo/feature-x    def5678 [feature-x]
```

---

### `gwtcd` - Git Worktree CD

Interactively select and change directory to a worktree using fzf.

**Usage:**
```bash
gwtcd
```

**Note:** This command requires fzf to be installed and always uses interactive selection.

---

### `gwtr` - Git Worktree Remove

Remove a worktree safely (fails if there are uncommitted changes).

**Usage:**
```bash
gwtr [worktree-path]
```

**Examples:**
```bash
# Remove specific worktree
gwtr feature/old-branch

# Interactive selection (requires fzf)
gwtr
```

**Note:** If no path is provided and fzf is installed, an interactive selector will appear.

---

### `gwtrm` - Git Worktree Remove (Force)

Force remove a worktree, even with uncommitted changes.

**Usage:**
```bash
gwtrm [worktree-path]
```

**Examples:**
```bash
# Force remove specific worktree
gwtrm feature/abandoned-branch

# Interactive selection (requires fzf)
gwtrm
```

**Note:** If no path is provided and fzf is installed, an interactive selector will appear.

---

### `gwtmv` - Git Worktree Move

Move a worktree to a new location.

**Usage:**
```bash
gwtmv <source> <destination>
```

**Examples:**
```bash
gwtmv feature/old-name feature/new-name
gwtmv ../old-location ../new-location
```

---

### `gwtp` - Git Worktree Prune

Clean up stale worktree references for directories that have been manually deleted.

**Usage:**
```bash
gwtp
```

---

### `gwtlock` - Git Worktree Lock

Lock a worktree to prevent it from being pruned or removed.

**Usage:**
```bash
gwtlock [worktree-path] [reason]
```

**Examples:**
```bash
# Lock specific worktree with reason
gwtlock feature/important "Work in progress"

# Interactive selection (requires fzf)
gwtlock
```

**Note:** If no path is provided and fzf is installed, an interactive selector will appear.

---

### `gwtunlock` - Git Worktree Unlock

Unlock a previously locked worktree.

**Usage:**
```bash
gwtunlock [worktree-path]
```

**Examples:**
```bash
# Unlock specific worktree
gwtunlock feature/important

# Interactive selection (requires fzf)
gwtunlock
```

**Note:** If no path is provided and fzf is installed, an interactive selector will appear.

---

### `gwtu` - Git Worktree Update

Fetch the latest from origin and rebase the current branch onto the default branch. Auto-detects the default branch (main/master) if not specified.

**Usage:**
```bash
gwtu [base-branch]
```

**Examples:**
```bash
# Rebase onto the auto-detected default branch
gwtu

# Rebase onto a specific branch
gwtu develop
```

**Alias:** `gwtup`

---

### `gwtclean` - Git Worktree Clean

Clean up worktrees and branches that have been merged into the default branch. Automatically detects the default branch (main/master) or you can specify a target branch. **Supports detection of squash merges!**

**Usage:**
```bash
gwtclean [target-branch] [-f]
```

**Options:**
- `-f` or `--force`: Skip confirmation and automatically clean up

**Examples:**
```bash
# Auto-detect default branch and clean up merged branches
gwtclean

# Clean up branches merged into specific branch
gwtclean develop

# Force cleanup without confirmation
gwtclean -f

# Clean branches merged into develop without confirmation
gwtclean develop -f
```

**What it does:**
1. Auto-detects the default branch (main/master) if not specified
2. Finds branches merged into the target branch using multiple detection methods:
   - **Traditional merges**: Branches merged with commit history preserved
   - **Squash merges**: Detects branches mentioned in merge commit messages
   - **Remote-deleted branches**: Branches whose remote was deleted (likely merged)
   - **Unpushed branches**: Local-only branches (asks for separate confirmation)
3. Lists worktrees associated with those merged branches
4. Removes both the worktrees and deletes the local branches
5. Handles branches without worktrees separately

**Safety features:**
- Asks for confirmation before deletion (unless `-f` flag is used)
- **Separately confirms unpushed local branches** before including them in cleanup
- Uses safe delete (`git branch -d`) which prevents deletion of unmerged changes
- Skips the current branch and target branch
- Properly cleans up shared directory symlinks
- Shows categorized lists of branches found (traditional, squash-merged, remote-deleted, unpushed)

**Alias:** `gwtcl`

---

## Aliases

The plugin also provides some convenient aliases:

- `gwt` → `git worktree`
- `gwtls` → `gwtl` (list worktrees)
- `gwtrp` → `gwtp` (prune worktrees)
- `gwtcl` → `gwtclean` (clean merged branches)
- `gwtup` → `gwtu` (fetch and rebase onto default branch)

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
