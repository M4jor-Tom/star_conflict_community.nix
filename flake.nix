{
  description = "Star Conflict community edition (game + local server) running under Wine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    chunky = {
      url = "github:M4jor-Tom/chunky";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Chunked game files (big ones split into .chunky/), only used to install the game when it's missing.
    game = {
      url = "git+https://github.com/M4jor-Tom/star_conflict_community.bin?ref=master&rev=3874ba46b5648152ed12e4115655a1cb4ba51e23&shallow=1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      chunky,
      game,
    }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      # wow64: runs the 32-bit servers without 32-bit host libs. Needs wine >= 11.x devel:
      # 11.0 lets 32-bit Hub.exe map memory across 4 GiB and it crashes on a wrapped pointer.
      wine = pkgs.wineWow64Packages.unstable;
      dxvk = pkgs.dxvk.bin;
    in
    {
      # Read by the launcher only when it installs, so the ~12 GB input stays out of its closure.
      legacyPackages.x86_64-linux.gameSrc = game.outPath;

      packages.x86_64-linux.default = pkgs.writeShellApplication {
        name = "star-conflict";
        runtimeInputs = [
          wine
          chunky.packages.x86_64-linux.default
        ];
        text = ''
          # Where Steam installs it (app 212070, installdir "star conflict"): a copy in any Steam library is
          # used as-is, otherwise the game is rebuilt into Steam's root from the chunked input, built aside so a
          # partial one never counts.
          share="''${XDG_DATA_HOME:-$HOME/.local/share}"
          steam=$(readlink -e "$HOME/.steam/steam" || echo "$share/Steam")
          dir="$steam/steamapps/common/star conflict"
          while IFS= read -r lib; do
            if [ -e "$lib/steamapps/common/star conflict/win64/game.exe" ]; then dir="$lib/steamapps/common/star conflict"; fi
          done < <(sed -n 's/^\s*"path"\s*"\(.*\)"$/\1/p' "$steam/steamapps/libraryfolders.vdf" 2>/dev/null)
          if [ ! -e "$dir/win64/game.exe" ]; then
            echo "Installing Star Conflict into $dir" >&2
            src=$(nix --extra-experimental-features 'nix-command flakes' eval --raw ${self}#legacyPackages.x86_64-linux.gameSrc)
            rm -rf "$dir.partial"
            mkdir -p "$(dirname "$dir")"
            cp -r --reflink=auto --no-preserve=mode "$src" "$dir.partial"
            (cd "$dir.partial" && chunky rebuild && rm -rf .chunky .gitignore)
            mv -T "$dir.partial" "$dir"
          fi

          export WINEPREFIX="''${WINEPREFIX:-$share/star-conflict}"
          # Run 32-bit exes in the launched process (not via start.exe), so $! is the real Hub.exe.
          export WINEARCH=wow64
          # DXVK for d3d9/d3d11; no Mono/Gecko (unused, would prompt for a download).
          export WINEDLLOVERRIDES="d3d8,d3d9,d3d10core,d3d11,dxgi=n,b;mscoree,mshtml,winemenubuilder.exe=d"
          export WINEDEBUG="''${WINEDEBUG:--all}"

          # wineboot -u resets system32, so redo the DXVK copy whenever wine or dxvk change.
          stamp="$WINEPREFIX/.nix-stamp"
          want="${wine.version} ${dxvk.version}"
          if [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
            wineboot -u
            wineserver -w
            install -m644 ${dxvk}/x64/*.dll "$WINEPREFIX/drive_c/windows/system32/"
            install -m644 ${dxvk}/x32/*.dll "$WINEPREFIX/drive_c/windows/syswow64/"
            echo "$want" >"$stamp"
          fi

          # Local server, as win64/local_server.xml would start it. Not via the game's -launchLocalServer:
          # on exit it sends CTRL_BREAK, which Wine turns into a thread abort, so MongoDB gets force-killed
          # and Hub's servers are orphaned. SIGINT (= CTRL_C) stops both cleanly.
          # Data and Hub logs: %LOCALAPPDATA%\Targem\StarConflict\cloud, server stdout: $WINEPREFIX/server.log.
          data="$WINEPREFIX/drive_c/users/''${USER:-$(id -un)}/AppData/Local/Targem/StarConflict/cloud/mongodb/data"
          mkdir -p "$data"
          exec 3>"$WINEPREFIX/server.log"
          cd "$dir/cloud/mongodb"
          wine mongod.exe --config config.cfg --dbpath "Z:$data" >&3 2>&3 &
          mongod=$!
          until (: >/dev/tcp/127.0.0.1/27017) 2>/dev/null; do
            kill -0 "$mongod" 2>/dev/null || { echo "MongoDB failed to start, see $WINEPREFIX/server.log" >&2; exit 1; }
            sleep 0.1
          done
          cd "$dir/cloud"
          wine Hub.exe >&3 2>&3 &
          hub=$!

          # Hub first: it stops its child servers, which still need MongoDB.
          stop() {
            kill -INT "$hub" 2>/dev/null && wait "$hub" || true
            kill -INT "$mongod" 2>/dev/null && wait "$mongod" || true
          }
          trap stop EXIT

          cd "$dir/win64"
          wine game.exe "$@"
        '';
      };
    };
}
