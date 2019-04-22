{pkgs ? import <nixpkgs> { } }:
with pkgs;

let

  macos-image = "buildkite-qemu-macos";
  linux-image = "buildkite-linux";
  metadata = builtins.fromJSON (builtins.readFile ./metadata.json);

  update-buildkite-version = writeShellScriptBin "update-buildkite-version" ''
    version=''${1:-}
    if [ -z "$version" ]; then
      echo "Please provide the wanted buildkite version"
      exit 1
    fi
    darwin_url="https://github.com/buildkite/agent/releases/download/v$version/buildkite-agent-darwin-amd64-$version.tar.gz"
    linux_url="https://github.com/buildkite/agent/releases/download/v$version/buildkite-agent-linux-amd64-$version.tar.gz"
    darwin_hash=$(nix-prefetch-url "$darwin_url")
    linux_hash=$(nix-prefetch-url "$linux_url")
    cat<<EOF>metadata.json
    {
      "darwin-sha256": "$darwin_hash",
      "linux-sha256": "$linux_hash",
      "linux-url": "$linux_url",
      "darwin-url": "$darwin_url",
      "version": "$version"
    }
    EOF
  '';

  build-containers = writeShellScriptBin "build-containers" ''
    set -euo pipefail
    registry=''${1:-}
    tag=''${2:-"${metadata.version}"}
    if [ -z "$registry" ]; then
      echo "Please provide the registry as the first argument"
      exit 1
    fi
    if [ -z "$tag" ]; then
      echo "Please provide the tag as the second argument"
      exit 1
    fi
    nix-build -o ${linux-image} --argstr dockerRegistry "$registry" --argstr dockerTag "$tag" docker-${linux-image}.nix
    nix-build -o ${macos-image} --argstr dockerRegistry "$registry" --argstr dockerTag "$tag" docker-${macos-image}.nix
  '';

  load-containers = writeShellScriptBin "load-containers" ''
    set -euo pipefail
    ${build-containers}/bin/build-containers $@
    ${docker}/bin/docker load < ${linux-image}
    ${docker}/bin/docker load < ${macos-image}
  '';

  push-containers = writeShellScriptBin "push-containers" ''
    set -euo pipefail
    registry=''${1:-}
    tag=''${2:-"${metadata.version}"}
    if [ -z "$registry" ]; then
      echo "Please provide the registry as the first argument"
      exit 1
    fi
    if [ -z "$tag" ]; then
      echo "Please provide the tag as the second argument"
      exit 1
    fi
    ${load-containers}/bin/load-containers $@
    ${docker}/bin/docker push "$registry"/${linux-image}:"$tag"
    ${docker}/bin/docker push "$registry"/${macos-image}:"$tag"
  '';

in

  mkShell {
    buildInputs = [
                   build-containers
                   load-containers
                   push-containers
                   update-buildkite-version
                  ];
  }