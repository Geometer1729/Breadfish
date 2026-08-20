{
  perSystem = { config, pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      name = "bread-bot";
      meta.description = "Haskell development environment";
      inputsFrom = [
        config.haskellProjects.default.outputs.devShell
        config.treefmt.build.devShell
      ];
      packages = with pkgs; [
        ghciwatch
        just
        nixd
      ];
    };
  };
}
