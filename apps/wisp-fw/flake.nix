{
  description = "Wisp native firmware (apps/wisp-fw): Zephyr toolchain + Renode, no sudo";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3.withPackages (ps: with ps; [
        west
        pyelftools
        pyyaml
        pykwalify
        packaging
        jsonschema
        anytree
        intelhex
        colorama
        ply
        psutil
        requests
        semver
        tqdm
        # tests/ble: a virtual BLE controller pair and a GATT central (Apache-2.0)
        bumble
      ]);
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.gcc-arm-embedded # 15.2.rel1, Zephyr toolchain variant "gnuarmemb"
          pkgs.cmake
          pkgs.ninja
          pkgs.dtc
          pkgs.gperf
          pkgs.git
          pkgs.gcc # host compiler for the Wisp Boot unit tests
          pkgs.renode # 1.16.x
        ];
        WISP_FW_DEVSHELL = "1";
        # native_sim builds at -O0; glibc's fortify warns about that on every file.
        hardeningDisable = [ "fortify" ];
        ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
        GNUARMEMB_TOOLCHAIN_PATH = "${pkgs.gcc-arm-embedded}";
      };
    };
}
