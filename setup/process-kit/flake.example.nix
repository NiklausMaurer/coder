# EXAMPLE dev toolchain for the coder autonomous loop — rename to `flake.nix`
# (and adapt) to activate it. The loop only enters `nix develop` when a real
# `flake.nix` exists; this `.example` file is inert until you rename it, so it
# can't break runs while you get it building.
#
# Why this exists: the loop runs your repo's `/implement` inside `nix develop`, so
# this devShell is what provides the toolchain your verify gate needs — the right
# language runtime, package manager, and any system tools (compilers, sqlite, …).
# Declaring it here keeps the coder image generic: it carries Nix, your repo
# carries its toolchain. Workflow once it builds: run `nix develop`, then
# `nix flake lock` and COMMIT flake.lock so the loop doesn't re-resolve nixpkgs
# every iteration (its `git clean -fd` wipes an untracked lock).
#
# The skeleton below is Node/pnpm-shaped — swap the `packages` and `shellHook` for
# your stack (e.g. `pkgs.go`, `pkgs.python312` + `pkgs.uv`, `pkgs.cargo`, …).
{
  description = "<your repo> dev toolchain for the coder loop";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # The tools your verify gate calls. Replace with your stack's.
          packages = [
            pkgs.nodejs_22
            pkgs.pnpm
          ];

          # Runs on every `nix develop` entry — including the loop's
          # `nix develop --command claude …`, before Claude starts. The loop's
          # per-iteration `git clean -fd` wipes untracked build outputs (e.g.
          # node_modules), so repopulate dependencies here. Keep it quiet and
          # non-fatal.
          shellHook = ''
            if [ -f pnpm-lock.yaml ]; then
              pnpm install --frozen-lockfile >/dev/null 2>&1 \
                || pnpm install >/dev/null 2>&1 || true
            fi
          '';
        };
      });
    };
}
