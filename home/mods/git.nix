{ ... }:
let
  stripNewlines = str: builtins.replaceStrings ["\n"] [""] str;
in {
  # home-manager options:
  # <https://nix-community.github.io/home-manager/options.html#opt-programs.git.enable>

  programs.git = {
    enable = true;

    userName = "Philip Hayes";
    userEmail = "philiphayes9@gmail.com";

    extraConfig = {
      core.editor = "nvim";
      commit.verbose = true;
      fetch.prune = true;
      pull.ff = "only";
      push.default = "simple";
      merge.conflictstyle = "diff3";

      # autosquash on rebase by default
      rebase.autosquash = true;
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
      pr = "!gh pr checkout";

      # Print the branch point of the current PR branch from the master branch.
      pr-base = "!git merge-base HEAD $(git master)";

      # Print which files have changed on this PR branch since master.
      pr-files = "!git diff --name-only $(git pr-base)";

      # Print the diff stat for the files changed on this PR branch.
      pr-stat = "!git diff --stat $(git pr-base)";

      # Open all changed files in `nvim` with gitgutter diff'ed against master.
      pr-rv = "!nvim $(git pr-files) +\"let g:gitgutter_diff_base = '$(git master)'\"";

      # Open only one specific changed file just like `git pr-review`
      pr-rvo = "!nvim +\"let g:gitgutter_diff_base = '$(git master)'\"";

      # Pretty print PR commits for Github PR description
      pr-desc = "!git log --format=tformat:'%x23%x23%x23 %B' $(git pr-base)..";

      # #############
      # # Shortcuts #
      # #############

      lg = stripNewlines ''
        log --graph --abbrev-commit --decorate --all
            --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(bold yellow)%d%C(reset)'
      '';
      ls = "ls-tree --name-only HEAD";
      s = "status";
      last = "log -1 HEAD";
      co = "checkout";
      sw = "switch";
      cm = "commit";
      cma = "commit -v --amend";
      cme = "commit -v --amend --no-edit";
      b = "branch";
      a = "add";
      d = "diff";
      p = "pull";
      plo = "!git pull --ff-only origin $(git master)";
      plu = "!git pull --ff-only upstream $(git master)";
      pfo = "push --force origin";
      pfom = "!git push --force origin $(git master)";
      pom = "!git push origin $(git master)";
      rb = "rebase";
      rbc = "rebase --continue";
      fu = "fetch upstream";
      fo = "fetch origin";
      ro = "!git rebase origin/$(git master)";
      ru = "!git rebase upstream/$(git master)";
    };

    ignores = [
      "*~"
      "*.swp"
      "tags"
      ".idea"
    ];
  };
}
