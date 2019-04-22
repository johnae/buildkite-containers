{dockerRegistry, dockerTag ? "latest", pkgs ? import <nixpkgs> { } }:
with pkgs;

let

  metadata = builtins.fromJSON (builtins.readFile ./metadata.json);
  buildkite-agent = with pkgs; stdenv.mkDerivation rec {
    version = metadata.version;
    name = "buildkite-agent-${version}";
    src = fetchurl {
      url = metadata.linux-url;
      sha256 = metadata.linux-sha256;
    };
    installPhase = ''
      mkdir -p $out/bin
      cp ../buildkite-agent $out/bin/
    '';
    buildPhase = "true";
  };

  paths = [
        buildkite-agent
        bashInteractive
        openssh
        coreutils
        gitMinimal
        gnutar
        gzip
        docker
        xz
        tini
        cacert
  ];

  nixImage = dockerTools.pullImage {
    imageName = "nixpkgs/nix";
    imageDigest = "sha256:aeedc164642644585fa0bb1d8cb9f08e102eb86ac2cb64d698c5f4451b944e4b";
    sha256 = "1ca4cdbgl3bn29n0n2l8c7cn3j28fb6lfyb3csplxv66n7yfmdpj";
  };

in

  dockerTools.buildImage {
    name = "${dockerRegistry}/buildkite-linux";
    tag = dockerTag;
    fromImage = nixImage;
    contents = paths ++ [ cacert iana-etc ./buildkite-linux-root ];
    config = {
      Entrypoint = [
              "${tini}/bin/tini" "-g" "--"
              "${buildkite-agent}/bin/buildkite-agent"
      ];
      Cmd = [ "start" ];
      Env = [
        "ENV=/etc/profile.d/nix.sh"
        "NIX_PATH=nixpkgs=channel:nixpkgs-unstable"
        "PAGER=cat"
        "PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "BUILDKITE_PLUGINS_PATH=/var/lib/buildkite/plugins"
        "BUILDKITE_HOOKS_PATH=/var/lib/buildkite/hooks"
        "BUILDKITE_BUILD_PATH=/var/lib/buildkite/builds"
      ];
      Volumes = {
        "/nix" = {};
      };
   };
  }