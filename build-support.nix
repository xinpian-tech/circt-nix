# Common packaging adaptations for standalone CIRCT, LLVM and MLIR.
{
  pkgs,
  upstreamLLVM,
  baseCirct,
  baseSlang,
  llvm-src,
  slang-src,
}:
let
  python = import ./python.nix { inherit pkgs; };
  # CIRCT tracks LLVM through its gitlink. Keep LLVM and MLIR as
  # independent derivations so all CIRCT configurations share them.
  # Fuzz 3 is needed for nixpkgs' GNU install-dir patch after the
  # per-target runtime-dir block was added upstream.
  llvmPatchFlags = [
    "-p1"
    "-F3"
  ];
  llvmPackages = upstreamLLVM.overrideScope (
    selfLLVM: superLLVM: {
      # llvm-tblgen is bootstrapped in its own derivation and applies
      # the same LLVM patches before the main libllvm build.
      tblgen = superLLVM.tblgen.overrideAttrs (_: {
        patchFlags = llvmPatchFlags;
      });

      libllvm =
        (superLLVM.libllvm.override {
          buildLlvmPackages = { inherit (selfLLVM) tblgen; };
          # Python loads several MLIR/CIRCT extension modules into one
          # process.  A monolithic LLVM dylib keeps those modules from
          # embedding independent copies of LLVM's global registries.
          enableSharedLibraries = true;
        }).overrideAttrs
          (old: {
            patchFlags = llvmPatchFlags;
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.z3 ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              # circt-nix defaults these to OFF after nixpkgs' own
              # flags, so repeat them at the end of the final list.
              "-DLLVM_BUILD_LLVM_DYLIB=ON"
              "-DLLVM_LINK_LLVM_DYLIB=ON"
              "-DLLVM_ENABLE_REVERSE_ITERATION=ON"
              "-DLLVM_ENABLE_Z3_SOLVER=ON"
            ];
            passthru = (old.passthru or { }) // {
              source = llvm-src;
            };
          });

      mlir =
        (superLLVM.mlir.override {
          buildLlvmPackages = { inherit (selfLLVM) tblgen; };
          inherit (selfLLVM) libllvm;
        }).overrideAttrs
          (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ python ];
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.z3 ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              # CIRCT links MLIR component targets directly.  Build
              # those components as shared libraries, all backed by
              # the one libLLVM dylib, instead of also creating a
              # second aggregate libMLIR representation.
              "-DBUILD_SHARED_LIBS=ON"
              "-DLLVM_BUILD_LLVM_DYLIB=OFF"
              "-DLLVM_LINK_LLVM_DYLIB=ON"
              "-DMLIR_LINK_MLIR_DYLIB=OFF"
              "-DLLVM_ENABLE_REVERSE_ITERATION=ON"
              "-DLLVM_ENABLE_Z3_SOLVER=ON"
              "-DMLIR_ENABLE_BINDINGS_PYTHON=ON"
              "-DMLIR_INSTALL_AGGREGATE_OBJECTS=ON"
              "-DPython_EXECUTABLE=${python}/bin/python3"
              "-DPython3_EXECUTABLE=${python}/bin/python3"
            ];
            passthru = (old.passthru or { }) // {
              inherit (selfLLVM) libllvm;
              source = llvm-src;
            };
          });
    }
  );
  inherit (llvmPackages) libllvm mlir;

  # Match CIRCT's Slang pin and use installed Nix dependencies.
  slang = baseSlang.overrideAttrs (old: {
    src = slang-src;
    version = "11.0";
    patches = builtins.filter (
      patch:
      let
        path = toString patch;
      in
      !(pkgs.lib.hasSuffix "slang-don-t-fetch-fmt.patch" path)
      && !(pkgs.lib.hasSuffix "slang-vendored-boost-headers.patch" path)
    ) (old.patches or [ ]);
    buildInputs = builtins.filter (dep: pkgs.lib.getName dep != "catch2") (old.buildInputs or [ ]);
    propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
      pkgs.boost
      pkgs.fmt
      pkgs.tomlplusplus
    ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DSLANG_INCLUDE_TESTS=OFF" ];
    postPatch = ''
      substituteInPlace source/util/VersionInfo.cpp.in \
        --subst-var SLANG_VERSION_MAJOR \
        --subst-var SLANG_VERSION_MINOR \
        --subst-var SLANG_VERSION_PATCH \
        --subst-var SLANG_VERSION_HASH
      substituteInPlace CMakeLists.txt \
        --replace-fail 'VERSION ''${SLANG_VERSION_STRING}' \
                       'VERSION "11.0"'
    '';
    SLANG_VERSION_MAJOR = "11";
    SLANG_VERSION_MINOR = "0";
    SLANG_VERSION_PATCH = "0";
    SLANG_VERSION_HASH = slang-src.shortRev or "dirty";
    doCheck = false;
  });

  mkCirct =
    args:
    (baseCirct.override (
      {
        inherit libllvm mlir slang;
        python3 = python;
      }
      // args
    )).overrideAttrs
      (old: {
        # Supply LLVM for both GitHub archives with an empty gitlink
        # directory and git+file sources that omit that directory.
        postUnpack = ''
          if [[ -e "$sourceRoot/llvm" || -L "$sourceRoot/llvm" ]]; then
            rm -rf -- "$sourceRoot/llvm"
          fi
          ln -s ${llvm-src} "$sourceRoot/llvm"
        '';
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace CMakeLists.txt \
              --replace-fail \
              '  if (CIRCT_BINDINGS_PYTHON_ENABLED)
                message(FATAL_ERROR "CIRCT Python bindings require a unified build. \
                                     See docs/PythonBindings.md.")
              endif()
            ' \
              '  # The Nix MLIR package exports its Python source targets.
              # This lets the standalone CIRCT package reuse installed MLIR.
            '
            substituteInPlace CMakeLists.txt \
              --replace-fail \
              '  mlir_configure_python_dev_packages()' \
              '  if(CIRCT_BUILT_STANDALONE)
                include(MLIRDetectPythonEnv)
              endif()
              mlir_configure_python_dev_packages()'
            # Standalone CIRCT globally disables exceptions and RTTI,
            # but every ESI runtime configuration requires both. Limit
            # the override to the runtime directory and its subtargets.
            substituteInPlace lib/Dialect/ESI/runtime/CMakeLists.txt \
              --replace-fail \
              'project(ESIRuntime LANGUAGES CXX)' \
              'project(ESIRuntime LANGUAGES CXX)

              if(NOT MSVC)
                add_compile_options(
                  "$<$<COMPILE_LANGUAGE:CXX>:-fexceptions>"
                  "$<$<COMPILE_LANGUAGE:CXX>:-frtti>"
                )
              endif()'

            # Tools already use LLVM_LINK_COMPONENTS to link the shared
            # LLVM library. Adjust the remaining direct component links
            # in tests and Python to avoid duplicating LLVM registries.
            substituteInPlace unittests/Conversion/ImportVerilog/CMakeLists.txt \
              --replace-fail '  LLVMSupport' ""
            substituteInPlace lib/Bindings/Python/CMakeLists.txt \
              --replace-fail '    LLVMSupport' '    LLVM'

            # Lit 18 keeps the per-test timeout on LitConfig, while the
            # source tree's newer lit keeps it on TestingConfig. Support
            # both APIs in the custom TableGen test format.
            substituteInPlace \
              test/Tools/circt-tblgen/self-contained/self_contained_td_format.py \
              --replace-fail \
              'timeout = test.config.maxIndividualTestTime or None' \
              'timeout = getattr(test.config, "maxIndividualTestTime",
                                getattr(litConfig, "maxIndividualTestTime", 0)) or None'

            # Let lit preserve the include search path supplied by the
            # check derivation for clang-tidy's SystemC smoke test.
            substituteInPlace integration_test/lit.cfg.py \
              --replace-fail \
              "['HOME', 'INCLUDE', 'LIB', 'TMP', 'TEMP']" \
              "['HOME', 'INCLUDE', 'LIB', 'TMP', 'TEMP', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH']"
          '';
        preConfigure =
          (old.preConfigure or "")
          + ''
            export CIRCT_SOURCE_ROOT="$PWD"
          '';
        buildInputs = (old.buildInputs or [ ]) ++ [
          pkgs.systemc
          pkgs.zlib.dev
          pkgs.lz4.dev
        ];
        preCheck =
          (old.preCheck or "")
          + ''
            # integration_test adds these source-tree wrappers directly
            # to PATH. Patch their /usr/bin/env shebangs inside the Nix
            # sandbox before lit tries to execute them.
            patchShebangs \
              "$CIRCT_SOURCE_ROOT/utils/circt-lec.sh" \
              "$CIRCT_SOURCE_ROOT/utils/equiv-rtl.sh"
            # Verilator's generated makefiles invoke g++ directly and
            # its timing support relies on GCC's coroutine flags.  A
            # direct PATH reference avoids activating a second compiler
            # setup hook during the Clang configure/build phases.
            export PATH="${pkgs.gcc}/bin:$PATH"
            # Verilator's FST runtime needs both zlib and lz4 when the
            # integration tests compile and run generated simulators.
            export CPLUS_INCLUDE_PATH="${pkgs.lib.getDev pkgs.systemc}/include:${pkgs.zlib.dev}/include:${pkgs.lz4.dev}/include:''${CPLUS_INCLUDE_PATH:-}"
            export LIBRARY_PATH="${pkgs.lib.getLib pkgs.zlib}/lib:${pkgs.lib.getLib pkgs.lz4}/lib:''${LIBRARY_PATH:-}"
            export LD_LIBRARY_PATH="${pkgs.lib.getLib pkgs.zlib}/lib:${pkgs.lib.getLib pkgs.lz4}/lib:''${LD_LIBRARY_PATH:-}"
          '';
        cmakeFlags =
          builtins.filter (
            flag:
            !(pkgs.lib.hasPrefix "-DLLVM_EXTERNAL_LIT=" flag) && !(pkgs.lib.hasPrefix "-DLLVM_LIT_ARGS=" flag)
          ) (old.cmakeFlags or [ ])
          ++ [
            "-DMLIR_MAIN_SRC_DIR=${llvm-src}/mlir"
            "-DMLIR_TOOLS_DIR=${mlir}/bin"
            # Replace circt-nix's Python 3.13 lit input entirely, not
            # merely later on the command line, so it is absent from
            # the derivation closure.
            "-DLLVM_EXTERNAL_LIT=${python}/bin/.lit-wrapped"
            # Never copy LLVM/MLIR registries into individual CIRCT
            # libraries or Python extension modules.
            "-DLLVM_LINK_LLVM_DYLIB=ON"
            "-DMLIR_LINK_MLIR_DYLIB=OFF"
          ];
      });
in
{
  inherit
    llvmPackages
    libllvm
    mlir
    mkCirct
    python
    slang
    ;
}
