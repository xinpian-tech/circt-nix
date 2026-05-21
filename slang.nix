{
  lib,
  stdenv,
  slang-src,
  fetchFromGitHub,
  fetchpatch,
  cmake,
  python3,
  catch2_3,
  mimalloc,
  enableMimalloc ? false,
}:

let
  getRev = src: src.shortRev or "dirty";
  mkVer =
    src:
    let
      date = builtins.substring 0 8 (src.lastModifiedDate or src.lastModified or "19700101");
    in
    "g${date}_${getRev src}";
  tag = "10.0";
  version = "${tag}${mkVer slang-src}";

  fmt_src = fetchFromGitHub {
    owner = "fmtlib";
    repo = "fmt";
    tag = "12.1.0";
    hash = "sha256-ZmI1Dv0ZabPlxa02OpERI47jp7zFfjpeWCy1WyuPYZ0=";
  };
  catch2_3_pinned = catch2_3.overrideAttrs (
    o:
    let
      version = "3.11.0";
    in
    {
      src = fetchFromGitHub {
        owner = "catchorg";
        repo = "catch2";
        tag = "v${version}";
        hash = "sha256-7Dx7PhtRwkbo8vHF57sAns2fQZ442D3cMyCt25RvzJc=";
      };
      inherit version;
    }
  );
in
stdenv.mkDerivation {
  pname = "slang";
  inherit version;
  nativeBuildInputs = [
    cmake
    python3
  ]
  ++ lib.optional enableMimalloc mimalloc;
  buildInputs = [
    python3
    catch2_3_pinned
  ];
  src = slang-src;

  patches = [
    ./patches/slang-don-t-fetch-fmt.patch
    ./patches/slang-pkgconfig.patch
    ./patches/slang-vendored-boost-headers.patch
    ./patches/slang-install-bs-thread-pool.patch
  ];

  # Builds w/mimalloc if have right version, disable for now.
  # SLANG_USE_THREADS=OFF: match what circt's FetchContent build of slang sets
  # ("avoid race condition in BS::thread_pool" - see circt CMakeLists.txt).
  # Mismatch causes AnalysisManager layout disagreement and stack smashing
  # when circt-verilog constructs a slang::analysis::AnalysisManager.
  cmakeFlags = [
    "-DSLANG_USE_MIMALLOC=${if enableMimalloc then "ON" else "OFF"}"
    "-DSLANG_USE_THREADS=OFF"
  ];

  # circt enables SLANG_ASSERT_ENABLED in its slang-consuming code whenever
  # LLVM_ENABLE_ASSERTIONS is on. Several slang classes (e.g. BumpAllocator)
  # have ABI-affecting `#if SLANG_ASSERT_ENABLED` fields, so the linked slang
  # library must be built with the same define or circt-verilog will crash.
  env.NIX_CFLAGS_COMPILE = "-DSLANG_ASSERT_ENABLED=1";

  postPatch = ''
    ln -s ${fmt_src} external/fmt

    substituteInPlace source/util/VersionInfo.cpp.in \
      --subst-var SLANG_VERSION_MAJOR \
      --subst-var SLANG_VERSION_MINOR \
      --subst-var SLANG_VERSION_PATCH \
      --subst-var SLANG_VERSION_HASH
    substituteInPlace CMakeLists.txt \
      --replace-fail 'VERSION ''${SLANG_VERSION_STRING}' \
                     'VERSION "${tag}"'
  '';

  SLANG_VERSION_MAJOR = lib.versions.major tag;
  SLANG_VERSION_MINOR = lib.versions.minor tag;
  SLANG_VERSION_PATCH = 0; # patch isn't safe if no patch level :(
  SLANG_VERSION_HASH = getRev slang-src;

  doCheck = true;

  meta = with lib; {
    description = "SystemVerilog compiler and language services";
    homepage = "https://sv-lang.com";
    license = with licenses; [ mit ]; # (ASL2.0 w/LLVM Exception)
    maintainers = with maintainers; [ dtzWill ];
  };
}
