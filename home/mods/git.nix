{
  lib,
  pkgs,
  ...
}:
let
  getBin = lib.getBin;
  writeBash = pkgs.writers.writeBash;

  stripNewlines = str: builtins.replaceStrings [ "\n" ] [ "" ] str;
in
{
  # home-manager options:
  # <https://nix-community.github.io/home-manager/options.html#opt-programs.git.enable>
  #
  # git config options:
  # <https://git-scm.com/docs/git-config#_variables>

  home.packages = [
    # git absorb - automatically create fixup commits for staged changes
    # <https://github.com/tummychow/git-absorb>
    pkgs.git-absorb
  ];

  programs.git = {
    enable = true;

    userName = lib.mkDefault "Philip Kannegaard Hayes";
    userEmail = lib.mkDefault "philiphayes9@gmail.com";

    # gpg commit signing
    signing = {
      # determine keypair to use by commit email. the name and email in the gpg
      # key must match "{userName} <{userEmail}>" EXACTLY.
      key = null;
      # sign all commits by default
      signByDefault = true;
    };

    extraConfig = {
      core.editor = "nvim";
      init.defaultBranch = "master";

      # silence annoying "detached head" warning
      advice.detachedHead = false;

      # Read `.git-blame-ignore-revs` file in each repo to ignore certain
      # commits when using `git blame`. Useful for ignoring bulk format commits.
      blame.ignoreRevsFile = ".git-blame-ignore-revs";

      # make `git branch` sort branches by last commit date. much easier to find
      # recent, non-stale branches this way.
      branch.sort = "-committerdate";

      # show full commit diff when editing commit message
      commit.verbose = true;

      # better quality diffs
      # see: <https://jvns.ca/blog/2024/02/16/popular-git-config-options/#diff-algorithm-histogram>
      diff.algorithm = "histogram";

      # before fetching, remove any remote-tracking refs that no longer exist
      # on the remote.
      fetch.prune = true;

      # show 3-way diff when resolving merge conflicts. `z-` also removes
      # duplicate lines from both sides of the conflict.
      merge.conflictstyle = "zdiff3";

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

      # enables `git-rerere(1)` which saves and reuses merge conflicts. Reduce
      # duplicate work on long rebases.
      rerere.enabled = true;

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

      # Open `nvim` with all unmerged branches (use --all to view all branches).
      # Then delete all the selected branches.
      rm-merged-branches =
        let
          jq = "${getBin pkgs.jq}/bin/jq";
          xargs = "${getBin pkgs.findutils}/bin/xargs";
          script = writeBash "git-rm-merged-branches" ''
            set -euo pipefail

            # Filter out current branch and master/main branches
            CURRENT_BRANCH="$(git branch --show-current --format='%(refname:short)')"
            JQ_SELECT_BRANCH_NAME=".branch != \"master\" and .branch != \"main\" and .branch != \"$CURRENT_BRANCH\""

            # By default, branches with no upstream are considered "merged"
            JQ_SELECT="select($JQ_SELECT_BRANCH_NAME and .upstream == \"\") | .branch"
            if [[ "$@" == "-a" || "$@" == "--all" ]]; then
              JQ_SELECT="select($JQ_SELECT_BRANCH_NAME) | .branch"
            fi

            TEMPFILE=$(mktemp)
            trap 'rm $TEMPFILE' EXIT

            # List the selected branches and open them in an editor first to
            # interactively choose which to delete.
            git branch --list --format='{"branch":"%(refname:short)","upstream":"%(upstream)"}' \
                | ${jq} -r "$JQ_SELECT" > $TEMPFILE
            $EDITOR $TEMPFILE
            ${xargs} git branch --delete --force < $TEMPFILE
          '';
        in
        "!${script}";

      #############
      # PR Review #
      #############

      # checkout a PR in the current repo
      pr = "!git switch $(git master) && git pull && gh pr checkout";

      # Print the branch point of the current PR branch from origin/master
      pr-base = stripNewlines ''
        !if [ -n "$PR_BASE" ]; then
            echo "$PR_BASE";
          else
            git merge-base HEAD origin/$(git master);
          fi
      '';

      # Print which files have changed on this PR branch since master.
      pr-files = "!git diff --name-only $(git pr-base)";

      # Print which files have changed on this PR branch in the current commit.
      cm-files = "!git diff --name-only HEAD~1";

      # Print the diff stat for the files changed on this PR branch.
      pr-stat = "!git diff --stat $(git pr-base)";

      # Print the diff stat for this commit.
      cm-stat = "!git diff --stat HEAD~1";

      # Open all changed files in `nvim` with gitgutter diff'ed against master.
      pr-rv = "!nvim $(git pr-files) +\"let g:gitgutter_diff_base = '$(git pr-base)'\"";

      # Open only one specific changed file just like `git pr-review`
      pr-rvo = "!nvim +\"let g:gitgutter_diff_base = '$(git pr-base)'\"";

      # Single commit: open all changed files in `nvim` with gitgutter diff.
      cm-rv = "!nvim $(git cm-files) +\"let g:gitgutter_diff_base = '$(git rev-parse HEAD~1)'\"";

      # Pretty print PR commits for Github PR description
      pr-desc = "!git log --format=tformat:'%x23%x23%x23 %B' $(git pr-base)..";

      # Start rebase to review by commit
      pr-rv-by-commit = "!git rebase --interactive $(git pr-base)";

      # #############
      # # Shortcuts #
      # #############

      a = "add";
      ab = "absorb";
      abr = "absorb --and-rebase";
      b = "branch";
      cm = "commit";
      cma = "commit --amend";
      cme = "commit --amend --no-edit";
      cmf = "commit --fixup";
      co = "checkout";
      cp = "cherry-pick";
      cpa = "cherry-pick --abort";
      cpc = "cherry-pick --continue";
      cpe = "cherry-pick --edit-todo";
      d = "diff";
      ds = "diff --staged";
      fo = "fetch origin";
      fu = "fetch upstream";
      fa = "fetch agent";
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
      rba = "rebase --abort";
      rbc = "rebase --continue";
      rbe = "rebase --edit-todo";
      rbo = "!git rebase origin/$(git master)";
      rbu = "!git rebase upstream/$(git master)";
      rs = "reset";
      rsh = "reset --hard";
      rsha = "!git reset --hard agent/$(git branch --show-current)";
      rsho = "!git reset --hard origin/$(git branch --show-current)";
      rshom = "!git reset --hard origin/$(git master)";
      rshu = "!git reset --hard upstream/$(git branch --show-current)";
      rshum = "!git reset --hard upstream/$(git master)";
      rsa = "!git reset origin/$(git master)";
      rso = "!git reset origin/$(git master)";
      rsu = "!git reset upstream/$(git master)";
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
      "/.vim"
    ];
  };
}
