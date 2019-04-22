with import ./buildkite.nix;
with pkgs.callPackage ./tools.nix { };
with builtins;
with lib;

{
  steps = agents [[ "queue=linux" "nix=true" ]] ([

     (step ":pipeline: Build and Push Containers" {
       command = ''
         nix-shell .buildkite/build.nix --run strict-bash <<'NIXSH'
           echo +++ Docker login
           echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" \
              --password-stdin

           echo +++ Build
           nix-shell --run "push-containers johnae"
         NIXSH
       '';
     })

  ]);
}