{...}: let
  stripNewlines = str: builtins.replaceStrings ["\n"] [""] str;
in {
  # home-manager options:
  # <https://nix-community.github.io/home-manager/options.html#opt-programs.git.enable>
  #
  # git config options:
  # <https://git-scm.com/docs/git-config#_variables>

  programs.git = {
    enable = true;

    userName = "Philip Hayes";
    userEmail = "philiphayes9@gmail.com";

    extraConfig = {
      core.editor = "nvim";
      init.defaultBranch = "master";

      # silence annoying "detached head" warning
      advice.detachedHead = false;

      # show full commit diff when editing commit message
      commit.verbose = true;

      # before fetching, remove any remote-tracking refs that no longer exist
      # on the remote.
      fetch.prune = true;

      # show 3-way diff when resolving merge conflicts.
      merge.conflictstyle = "diff3";

      # when pulling from a remote branch, don't try to make a merge commit
      # if we can't fast-forward, just fail.
      pull.ff = "only";

      # allow plain `git push` for new branches w/o any extra work.
      push.autoSetupRemote = true;

      # push.default defines the action `git push` should take by default.
      # simple = pushes the current branch w/ the same name on remote
      push.default = "simple";

      # autosquash on rebase by default
      rebase.autosquash = true;

      # show detailed diff by default for `git stash show`
      stash.showPatch = true;
    };

    aliases = {
      #############
      # Utilities #
      #############

      # Print the current repo's "master" branch name ("master" or "main").
      master = stripNewlines ''
        !git branch --list --format="%(refname)"
            | sed -n -E "s/^refs\\/heads\\/(master|main)$/\\1/p"
            | head --lines=1
      '';

      #############
      # PR Review #
      #############

      # checkout a PR in the current repo
      pr = "!git switch $(git master) && git pull && gh pr checkout";

      # Print the branch point of the current PR branch from the master branch.
      pr-base = "!git merge-base HEAD $(git master)";

      # Print which files have changed on this PR branch since master.
      pr-files = "!git diff --name-only $(git pr-base)";

      # Print which files have changed on this PR branch in the current commit.
      cm-files = "!git diff --name-only HEAD~1";

      # Print the diff stat for the files changed on this PR branch.
      pr-stat = "!git diff --stat $(git pr-base)";

      # Print the diff stat for this commit.
      cm-stat = "!git diff --stat HEAD~1";

      # Open all changed files in `nvim` with gitgutter diff'ed against master.
      pr-rv = "!nvim $(git pr-files) +\"let g:gitgutter_diff_base = '$(git master)'\"";

      # Open only one specific changed file just like `git pr-review`
      pr-rvo = "!nvim +\"let g:gitgutter_diff_base = '$(git master)'\"";

      # Single commit: open all changed files in `nvim` with gitgutter diff.
      cm-rv = "!nvim $(git cm-files) +\"let g:gitgutter_diff_base = '$(git rev-parse HEAD~1)'\"";

      # Pretty print PR commits for Github PR description
      pr-desc = "!git log --format=tformat:'%x23%x23%x23 %B' $(git pr-base)..";

      # Start rebase to review by commit
      pr-rv-by-commit = "!git rebase --interactive $(git master)";

      # #############
      # # Shortcuts #
      # #############

      a = "add";
      b = "branch";
      cm = "commit";
      cma = "commit -v --amend";
      cme = "commit -v --amend --no-edit";
      cmf = "commit -v --fixup";
      co = "checkout";
      d = "diff";
      ds = "diff --staged";
      fo = "fetch origin";
      fu = "fetch upstream";
      last = "log -1 HEAD";
      lg = stripNewlines ''
        log --graph --abbrev-commit --decorate --all
            --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(bold yellow)%d%C(reset)'
      '';
      ls = "ls-tree --name-only HEAD";
      p = "pull";
      pfo = "push --force origin";
      pfom = "!git push --force origin $(git master)";
      plo = "!git pull --ff-only origin $(git master)";
      plu = "!git pull --ff-only upstream $(git master)";
      pom = "!git push origin $(git master)";
      rb = "rebase";
      rbe = "rebase --edit-todo";
      rbc = "rebase --continue";
      ro = "!git rebase origin/$(git master)";
      ru = "!git rebase upstream/$(git master)";
      s = "status";
      sw = "switch";
      unwip = "!git reset --soft HEAD~1 && git restore --staged .";
      wip = "!git add . && git commit -m WIP";
    };

    ignores = [
      "*~"
      "*.swp"
      "tags"
      ".idea"
    ];
  };
}
