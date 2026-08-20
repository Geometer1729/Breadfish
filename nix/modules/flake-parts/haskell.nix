{ root, inputs, ... }:
{
  imports = [ inputs.haskell-flake.flakeModule ];

  perSystem = { self', lib, config, ... }: {
    haskellProjects.default = {
      projectRoot = builtins.toString (lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions [
          (root + /app)
          (root + /src)
          (root + /test)
          (root + /bread-bot.cabal)
          (root + /LICENSE)
          (root + /README.md)
        ];
      });

      devShell.hlsCheck.enable = false;
      autoWire = [ "packages" "apps" "checks" ];
    };

    packages.default = self'.packages.bread-bot;
    apps.default = self'.apps.bread-bot;
    checks.bread-bot = self'.packages.bread-bot;
  };
}
