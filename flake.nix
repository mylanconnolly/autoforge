{
  description = "AutoForge – Phoenix/Ash AI coding environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    claude-code,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};

        erlang = pkgs.beam.interpreters.erlang_28;
        beamPkgs = pkgs.beam.packagesWith erlang;
        elixir = beamPkgs.elixir_1_19;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs =
            [
              erlang
              elixir
              pkgs.docker-compose
              pkgs.inotify-tools # for Phoenix live reload
              pkgs.watchman # for Tailwind CSS file watching
              pkgs.tailwindcss_4 # CSS compilation
              pkgs.esbuild # JS compilation

              # AI tooling
              claude-code.packages.${system}.default
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (
              with pkgs.darwin.apple_sdk.frameworks; [
                CoreFoundation
                CoreServices
              ]
            );

          shellHook = ''
            mkdir -p .nix-mix .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export MIX_PATH="${beamPkgs.hex}/lib/erlang/lib/hex/ebin"
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            export LANG=C.UTF-8
            export ERL_AFLAGS="-kernel shell_history enabled"
            export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) / 2 ))

            # Database config for local docker-compose Postgres
            export DATABASE_URL="postgres://auto_forge:auto_forge@localhost:5432/auto_forge_dev"
            export POSTGRES_HOST=localhost
            export POSTGRES_PORT=5432
            export POSTGRES_USER=auto_forge
            export POSTGRES_PASSWORD=auto_forge
            export POSTGRES_DB=auto_forge_dev

            # Source .env file if present
            if [ -f .env ]; then
              set -a
              source .env
              set +a
            else
              echo "⚠  No .env found — copy .env.example to .env and fill in your keys"
            fi

            if [ -n "''${FLUXON_AUTH_KEY:-}" ]; then
              if ! mix hex.repo list 2>/dev/null | grep -q fluxon; then
                mix hex.repo add fluxon https://repo.fluxonui.com \
                  --fetch-public-key "''${FLUXON_PUBLIC_KEY}" \
                  --auth-key "''${FLUXON_AUTH_KEY}"
              fi
            else
              echo "⚠  FLUXON_AUTH_KEY not set — skipping Fluxon repo registration"
            fi
          '';
        };
      }
    );
}
