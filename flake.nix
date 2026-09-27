{
  description = "circt-y things";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    circt-src = {
      url = "github:xinpian-tech/circt/master";
      flake = false;
    };

    llvm-src = {
      type = "github";
      owner = "llvm";
      repo = "llvm-project";
      rev = "e297b52ec9d8b5c38042e53ae5650922717970cd";
      flake = false;
    };

    # Pinned to the exact commit CIRCT's CMakeLists.txt FetchContent-pins
    # (v11.0 + ~85 commits). CIRCT's ImportVerilog tests are tuned to this
    # revision's diagnostics (llvm/circt#10717), so a plain v11.0 release
    # tag is not sufficient -- keep this in sync with CIRCT's GIT_TAG.
    slang-src = {
      url = "github:MikePopoloski/slang/44dc55f99b9c64971893013e7931e643fbedcf23";
      flake = false;
    };

    cli11-src = {
      url = "github:CLIUtils/CLI11/v2.5.0";
      flake = false;
    };
    fmt-src = {
      url = "github:fmtlib/fmt/11.1.4";
      flake = false;
    };
    googletest-src = {
      url = "github:google/googletest/v1.15.2";
      flake = false;
    };
    ixwebsocket-src = {
      url = "github:machinezone/IXWebSocket/173f442474c4d9db16184c5e15cc96e07605e0e0";
      flake = false;
    };
    nlohmann-json-src = {
      url = "github:nlohmann/json/v3.11.3";
      flake = false;
    };
    zlib-src = {
      url = "github:madler/zlib/5a82f71ed1dfc0bec044d9702463dbdf84ea3b71";
      flake = false;
    };

    # From README.md: https://github.com/edolstra/flake-compat
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      circt-src,
      llvm-src,
      flake-compat,
      slang-src,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Systems we build for.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Helper utilities for our flake.
      # "Borrowed" from flake-utils.
      #
      # eachSystem: call `f system` for each system and transpose the
      # results, so `{ packages = ...; }` per system becomes the flake's
      # `{ packages.<system> = ...; }`. Attrs missing on some systems are
      # only emitted for the systems that provide them.
      eachSystem =
        f:
        let
          perSystem = lib.genAttrs systems f;
          attrNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues perSystem));
        in
        lib.genAttrs attrNames (
          attr:
          lib.genAttrs (lib.filter (system: perSystem.${system} ? ${attr}) systems) (
            system: perSystem.${system}.${attr}
          )
        );

      # mkApp: build a flake `app` output pointing at a binary in `drv`.
      mkApp =
        {
          drv,
          name ? drv.meta.mainProgram or drv.pname,
        }:
        {
          type = "app";
          program = "${drv}/bin/${name}";
        };

      circtVersion = "1.160.0";

      overlay =
        final: prev:
        let
          circtSrc = circt-src;
          llvmSrc = llvm-src;
          baseLLVM = prev.lib.recurseIntoAttrs (
            prev.callPackages ./llvm.nix {
              inherit llvmSrc;
              llvmRev = llvm-src.rev;
              llvmPackages = final.llvmPackages_git;
              # TODO: Get this handled for us, spliced in?
              buildLLVMPackages_circt = final.buildPackages.llvmPackages_circt;
            }
          );
          baseSlang = prev.callPackage ./slang.nix { inherit slang-src; };
          baseCirct = prev.callPackage ./circt.nix {
            inherit circtSrc;
            version = circtVersion;
            inherit (baseLLVM) libllvm mlir llvm-third-party-src;

            # Override nixpkgs' lit, it uses pypi which is pinned to 18.1.8.
            # We need newer version. Fix this upstream!
            lit = prev.lit.overrideAttrs (o: {
              name = "lit-${baseLLVM.libllvm.version}";
              version = baseLLVM.libllvm.version;
              src = "${llvmSrc}/llvm/utils/lit";
              patches = o.patches or [ ] ++ [
                ./patches/lit-shell-script-runner-set-dyld-library-path.patch
              ];
            });
            # CIRCT statically links slang (libsvlang.a), so this variant is
            # embedded in CIRCT and never shipped as a CLI -- disabling
            # threads here matches how CIRCT configures slang when it builds
            # it from source, while leaving the standalone `slang` package
            # (with its -j option) untouched.
            slang = baseSlang.override { enableThreads = false; };
          };
          core = import ./build-support.nix {
            pkgs = prev;
            upstreamLLVM = baseLLVM;
            inherit
              baseCirct
              baseSlang
              llvm-src
              slang-src
              ;
          };
          circtFlakePkgs = {
            llvmPackages_circt = core.llvmPackages;
            inherit (core)
              libllvm
              mlir
              mkCirct
              slang
              ;
            circt = core.mkCirct { };
            circtPython = core.python;
            # The wrapper needs Bash to load its standard-header search paths.
            clang-tools = prev.clang-tools.overrideAttrs (old: {
              postInstall =
                (old.postInstall or "")
                + ''
                  substituteInPlace "$out/bin/clang-tidy" \
                    --replace-fail '#!/bin/sh' '#!${prev.bash}/bin/bash'
                '';
            });
            espresso = prev.callPackage ./espresso.nix { };
          };
        in
        { inherit circtFlakePkgs; } // circtFlakePkgs;
    in
    eachSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      rec {
        formatter = pkgs.nixfmt-tree;
        devShells =
          {
            default = import ./shell.nix { inherit pkgs; };
          }
          // pkgs.lib.optionalAttrs
            (
              !pkgs.stdenv.isDarwin # libcxxabi git on Darwin is broken?
            )
            {
              git = import ./shell.nix {
                inherit pkgs;
                llvmPkgs = pkgs.llvmPackages_git; # NOT same as submodule.
              };
            };
        packages =
          (pkgs.lib.removeAttrs pkgs.circtFlakePkgs [
            "llvmPackages_circt"
            "mkCirct"
          ])
          // {
            default = pkgs.circt; # default for `nix build` etc.
            # selectively expose packages from llvmPackages_circt.
            # clang/etc are not tested and patches/builds may break.
            inherit (pkgs.circtFlakePkgs.llvmPackages_circt) libllvm mlir;
          };
        apps = pkgs.lib.genAttrs [ "firtool" "circt-lsp-server" "circt-verilog-lsp-server" ] (
          name:
          mkApp {
            drv = packages.circt;
            inherit name;
          }
        );

        # Expose nixpkgs with the overlay applied under legacyPackages.
        #
        # Was a second `import nixpkgs` that also passed
        # `crossOverlays = [ overlay ]` (f8b2b85), i.e. an extra nixpkgs
        # instantiation per system. Redundant: plain `overlays` already
        # reaches cross sets -- pkgsCross.*.circt still evaluates without it
        # -- so crossOverlays only applied the overlay a *second* time to the
        # cross stage. That double application perturbed derivations (native
        # `hello` included, so legacyPackages.<pkg> silently diverged from
        # packages.<pkg>) and made tomlplusplus and glibc-iconv hit infinite
        # recursion. Not specific to our overlay: a trivial
        # `{ probe = 42; }` crossOverlay reproduces it.
        legacyPackages = pkgs;
      }
    )
    // {
      overlays.default = overlay;
    };

  nixConfig = {
    extra-substituters = [ "https://dtz-circt.cachix.org" ];
    extra-trusted-public-keys = [
      "dtz-circt.cachix.org-1:PHe0okMASm5d9SD+UE0I0wptCy58IK8uNF9P3K7f+IU="
    ];
  };
}
