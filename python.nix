{ pkgs }:

pkgs.python312.withPackages (
  ps:
  let
    cocotb = ps.cocotb.overridePythonAttrs (_: {
      version = "1.9.2";
      src = pkgs.fetchFromGitHub {
        owner = "cocotb";
        repo = "cocotb";
        tag = "v1.9.2";
        hash = "sha256-7KCo7g2I1rfm8QDHRm3ZKloHwjDIICnJCF8KhaFdvqY=";
      };
      postPatch = ''
        patchShebangs bin/*.py
      '';
      doCheck = false;
    });
    cocotbTest = ps.buildPythonPackage rec {
      pname = "cocotb_test";
      version = "0.2.6";
      format = "setuptools";
      src = pkgs.fetchPypi {
        inherit pname version;
        hash = "sha256-pGYZSMoUXu5rzK+DIXS177n200IGdxV8BK3nK7IWBpI=";
      };
      propagatedBuildInputs = [ cocotb ];
      doCheck = false;
    };
    nanobind = ps.nanobind.overridePythonAttrs (_: {
      version = "2.9.2";
      src = pkgs.fetchgit {
        url = "https://github.com/wjakob/nanobind";
        rev = "b775c42f2eb3cac13efc5bc266766066306898a6";
        fetchSubmodules = true;
        hash = "sha256-cC+sf2FUm1jdGMRdDoaQK8rjUVkWjn/53c1HQ5gsUWs=";
      };
    });
    pybind11 = ps.buildPythonPackage rec {
      pname = "pybind11";
      version = "2.11.2";
      pyproject = true;
      src = pkgs.fetchFromGitHub {
        owner = "pybind";
        repo = "pybind11";
        tag = "v${version}";
        hash = "sha256-F8+bb6wZ/BygzMGN1q48X9qzYsCUWanuj/MiZ1s8ShM=";
      };
      build-system = [
        ps.cmake
        ps.ninja
        ps.setuptools
      ];
      dontUseCmakeConfigure = true;
      doCheck = false;
      postInstall = ''
        ln -s "$out/${pkgs.python312.sitePackages}/pybind11/include" "$out/include"
        ln -s "$out/${pkgs.python312.sitePackages}/pybind11/share" "$out/share"
      '';
    };
  in
  [
    ps.click
    cocotb
    cocotbTest
    ps.executing
    ps.jinja2
    ps.lit
    nanobind
    ps.numpy
    ps.packaging
    ps.psutil
    pybind11
    ps.pycapnp
    ps.pytest
    ps.pytest-xdist
    ps.pyyaml
    ps.setuptools
    ps.typing-extensions
    ps.wheel
  ]
)
