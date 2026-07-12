let
  flake = builtins.getFlake (toString ./.);
in
flake.packages.${builtins.currentSystem}.hello-sh
