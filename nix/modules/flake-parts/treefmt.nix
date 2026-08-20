{ inputs, ... }:
{
  imports = [
    inputs.treefmt-nix.flakeModule
    inputs.fourmolu-nix.flakeModule
  ];

  perSystem = { config, ... }: {
    treefmt.config = {
      projectRootFile = "flake.nix";
      settings.global.excludes = [
        ".direnv/**"
        "dist-newstyle/**"
        "result"
        "result-*"
      ];
      programs = {
        cabal-fmt.enable = true;
        hlint.enable = true;
        nixpkgs-fmt.enable = true;
        fourmolu = {
          enable = true;
          package = config.fourmolu.wrapper;
        };
      };
    };

    fourmolu.settings = {
      indentation = 2;
      column-limit = 80;
      comma-style = "leading";
      record-brace-space = true;
      indent-wheres = true;
      import-export-style = "diff-friendly";
      respectful = true;
      haddock-style = "multi-line";
      newlines-between-decls = 1;
      extensions = [ "ImportQualifiedPost" ];
    };
  };
}
