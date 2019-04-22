{dockerRegistry, dockerTag ? "latest", pkgs ? import <nixpkgs> { } }:
with pkgs;

let

  metadata = builtins.fromJSON (builtins.readFile ./metadata.json);
  buildkite-macos-agent = with pkgs; stdenv.mkDerivation rec {
    version = metadata.version;
    name = "buildkite-macos-agent-${version}";
    src = fetchurl {
      url = metadata.darwin-url;
      sha256 = metadata.darwin-sha256;
    };
    installPhase = ''
      mkdir -p $out/bin
      cp ../buildkite-agent $out/bin/
    '';
    buildPhase = "true";
  };

  boot-vm = with pkgs; writeShellScriptBin "boot-vm" ''
    if [ -z "$BASEHDD" ]; then
      echo "BASEHDD var '$BASEHDD' must be set to an existing file"
      exit 1
    fi

    if [ -z "$WRITESHDD" ]; then
      echo "WRITESHDD var '$WRITESHDD' must be set to some path (will be created on boot)"
      exit 1
    fi

    if [ -z "$CLOVER_IMAGE" ] || [ ! -e "$CLOVER_IMAGE" ]; then
      echo "CLOVER_IMAGE var '$CLOVER_IMAGE' must be set to an existing file"
      exit 1
    fi

    if [ -z "$OVMF_CODE" ] || [ ! -e "$OVMF_CODE" ]; then
      echo "OVMF_CODE var '$OVMF_CODE' must be set to an existing file"
      exit 1
    fi

    if [ -z "$OVMF_VARS" ] || [ ! -e "$OVMF_VARS" ]; then
      echo "OVMF_VARS var '$OVMF_VARS' must be set to an existing file"
    fi

    cp "$CLOVER_IMAGE" /clover.qcow2
    cp "$OVMF_CODE" /ovmf_code.fd
    cp "$OVMF_VARS" /ovmf_vars.fd

    if [ -z "$KEEP_DATA" ]; then
      rm -f "$WRITESHDD"
    fi

    if [ -z "$BASEHDD" ] || [ ! -e "$BASEHDD" ]; then
      echo "$BASEHDD does not exist - boom"
      exit 1
    fi

    if [ ! -e "$WRITESHDD" ]; then
      qemu-img create -f qcow2 -b "$BASEHDD" "$WRITESHDD"
    fi

    QEMU_OPTIONS="+pcid,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"
    exec qemu-system-x86_64 -enable-kvm -m 3072 -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,$QEMU_OPTIONS \
      -machine pc-q35-2.11 \
      -smp 4,cores=2 \
      -usb -device usb-kbd -device usb-tablet \
      -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
      -drive if=pflash,format=raw,readonly,file=/ovmf_code.fd \
      -drive if=pflash,format=raw,file=/ovmf_vars.fd \
      -smbios type=2 \
      -device ich9-intel-hda -device hda-duplex \
      -device ide-drive,bus=ide.2,drive=Clover \
      -drive id=Clover,if=none,snapshot=on,format=qcow2,file=/clover.qcow2 \
      -device ide-drive,bus=ide.0,drive=MacDVD \
      -drive id=MacDVD,if=none,snapshot=on,media=cdrom,file=/cloudinit.iso \
      -device ide-drive,bus=ide.1,drive=MacHDD \
      -drive id=MacHDD,if=none,snapshot=off,file="$WRITESHDD",format=qcow2 \
      -netdev user,hostfwd=tcp::10022-:22,id=net0 -device e1000-82545em,netdev=net0,id=net0,mac=52:54:00:AB:FA:1F \
      -vnc 0.0.0.0:0 -k sv
  '';

  start-vm = writeShellScriptBin "start-vm" ''
    export BUILDKITE_AGENT_NAME=$HOSTNAME
    env | grep -vE '^PATH=|^HOME=|^USER=' > /cloudinit/env
    cp "$SSH_KEY_PATH" /cloudinit/id_rsa
    cat /cloudinit/env

    mkdir -p /tmp
    chmod 777 /tmp
    export TMPDIR=/tmp

    cp ${buildkite-macos-agent}/bin/buildkite-agent /cloudinit/
    cat<<EOF>/cloudinit/cloudinit.sh
    #!/usr/bin/env bash

    finish() {
      echo "exiting and shutting down now"
      sudo shutdown -h now
    }
    trap finish EXIT

    DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)"

    set -a
    . "\$DIR"/env
    set +a

    mkdir -p "\$HOME"/.ssh
    chmod 0700 "\$HOME"/.ssh
    cp "\$DIR"/id_rsa "\$HOME"/.ssh/id_rsa
    sudo chown \$USER "\$HOME"/.ssh/id_rsa
    sudo chmod 0600 "\$HOME"/.ssh/id_rsa

    . "\$HOME"/.profile
    nix-env -iA nixpkgs.git

    if [ -n "\$BUILDKITE_STORE_PATH" ]; then
      sudo mkdir -p "\$BUILDKITE_STORE_PATH"
    fi
    sudo chown -R \$USER "\$BUILDKITE_STORE_PATH"

    if [ -n "\$BUILDKITE_BUILD_PATH" ]; then
      sudo mkdir -p "\$BUILDKITE_BUILD_PATH"
    fi
    sudo chown -R \$USER "\$BUILDKITE_BUILD_PATH"

    if [ -n "\$BUILDKITE_PLUGINS_PATH" ]; then
      sudo mkdir -p "\$BUILDKITE_PLUGINS_PATH"
    fi
    sudo chown -R \$USER "\$BUILDKITE_PLUGINS_PATH"

    "\$DIR"/buildkite-agent $@
    EOF
    chmod +x /cloudinit/cloudinit.sh
    cat /cloudinit/cloudinit.sh

    mkisofs -r -U -J -joliet-long -o /cloudinit.iso /cloudinit
    ${boot-vm}/bin/boot-vm
  '';

  paths = [
    kvm
    cdrkit
    gnugrep
    start-vm
    coreutils
  ];

in

  dockerTools.buildLayeredImage {
    name = "${dockerRegistry}/buildkite-qemu-macos";
    tag = dockerTag;
    contents = paths;
    config = {
    Entrypoint = [ "${start-vm}/bin/start-vm" ];
    Volumes = {
      "/cloudinit" = {};
    };
   };
  }