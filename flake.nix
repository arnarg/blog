{
  description = "My website generated using nixtml.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixtml.url = "github:arnarg/nixtml";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nixtml,
    }:
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.blog = nixtml.lib.mkWebsite {
          inherit pkgs;

          name = "codedbearder";
          baseURL = "https://codedbearder.com";

          metadata = {
            lang = "en";
            title = "codedbearder";
            description = "codedbearder's blog";
            copyright = "© Arnar Gauti Ingason";

            socials = {
              github = "arnarg";
              linkedin = "arnari";
              mastodon = "https://floss.social/@arnar";
            };
          };

          content.dir = ./content;
          static.dir = ./static;

          collections.blog = {
            path = "posts";
            taxonomies = [ "tags" ];
          };

          imports = [ ./theme.nix ];
        };

        apps = {
          # Serve blog
          serve = {
            type = "app";
            program =
              (pkgs.writeShellScript "serve-blog" ''
                ${pkgs.python3}/bin/python -m http.server -d ${self.packages.${system}.blog} 8080
              '').outPath;
          };
        };
      }
    ));
}
