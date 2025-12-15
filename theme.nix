{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (config.website) metadata;
  inherit (config.website.layouts) partials;
  inherit (lib) attrs;
  inherit (lib.tags)
    a
    article
    body
    div
    footer
    h1
    h2
    head
    header
    html
    img
    link
    main
    meta
    p
    section
    strong
    ;
in
{
  website.layouts = {
    base =
      { path, content, ... }@context:
      "<!DOCTYPE html>\n"
      +
        html
          [ (attrs.lang metadata.lang) ]
          [
            (head [ ] [ (partials.head context) ])
            (body
              [
                (attrs.classes [
                  "font-sans"
                  "bg-white"
                  "dark:bg-stone-900"
                  "text-stone-900"
                  "dark:text-stone-200"
                ])
              ]
              [
                (div
                  [
                    (attrs.classes [
                      "container"
                      "max-w-3xl"
                      "mx-auto"
                      "px-4"
                    ])
                  ]
                  [
                    (partials.nav context)
                    content
                    (partials.footer context)
                  ]
                )
              ]
            )
          ];

    page =
      { metadata, content, ... }:
      main
        [ ]
        [
          (article
            [ (attrs.classes [ "max-w-3xl" ]) ]
            [
              (h1 [ (attrs.classes [ "my-6 !font-light" ]) ] [ metadata.title ])
              (div
                [
                  (attrs.classes [
                    "mb-2"
                    "text-stone-900"
                    "dark:text-stone-200"
                  ])
                ]
                [
                  "Posted on ${metadata.date}"
                ]
              )
              (div
                [
                  (attrs.classes [
                    "flex"
                    "flex-row"
                    "gap-4"
                  ])
                ]
                (
                  map (
                    tag:
                    a
                      [
                        (attrs.classes [ "no-underline" ])
                        (attrs.href "/tags/${tag}")
                      ]
                      [ "#${tag}" ]
                  ) metadata.tags
                )
              )
              (img [
                (attrs.classes [ "rounded" ])
                (attrs.src metadata.thumbnail)
                (attrs.alt "thumbnail")
              ])
              content
              (partials.discuss metadata)
            ]
          )
        ];

    collection =
      {
        items,
        ...
      }@context:
      main
        [ ]
        [
          (section [ ] (
            (map (post: config.website.layouts.partials.post post) items)
            ++ [ (config.website.layouts.partials.pagination context) ]
          ))
        ];

    taxonomy =
      {
        title,
        items,
        ...
      }@context:
      main
        [ ]
        [
          (section [ ] (
            [
              (h1
                [
                  (attrs.classes [
                    "font-light"
                    "text-3xl"
                  ])
                ]
                [ ("#" + title) ]
              )
            ]
            ++ (map (post: config.website.layouts.partials.post post) items)
            ++ [ (config.website.layouts.partials.pagination context) ]
          ))
        ];

    partials = {
      head =
        {
          path,
          ...
        }@context:
        [
          (link [
            (attrs.rel "stylesheet")
            (attrs.href "/css/main.css")
          ])
          (meta [
            (attrs.httpEquiv "content-type")
            (attrs.content "text/html")
            (attrs.charset "UTF-8")
          ])
          (meta [
            (attrs.httpEquiv "x-ua-compatible")
            (attrs.content "IE=edge,chrome=1")
          ])
          (meta [
            (attrs.name "viewport")
            (attrs.content "width=device-width, initial-scale=1.0")
          ])
          (meta [
            (attrs.name "msapplication-TileColor")
            (attrs.name "#da532c")
          ])
          (meta [
            (attrs.name "theme-color")
            (attrs.name "#ffffff")
          ])
          (link [
            (attrs.rel "icon")
            (attrs.href "/favicon.png")
          ])
          (
            if path == [ "index.html" ] then
              link [
                (attrs.rel "alternate")
                (attrs.type "application/rss+xml")
                (attrs.href "${config.website.baseURL}/${config.website.collections.blog.rss.path}")
                (attrs.title metadata.title)
              ]
            else
              ""
          )
          (partials.meta context)
        ];

      meta =
        { path, title, ... }:
        let
          pageTitle = if title != null then "${title} | ${metadata.title}" else metadata.title;
        in
        [
          (lib.tags.title pageTitle)
          (meta [
            (attrs.name "description")
            (attrs.content metadata.description)
          ])
          (meta [
            (attrs.property "og:title")
            (attrs.content pageTitle)
          ])
          (meta [
            (attrs.property "twitter:title")
            (attrs.content pageTitle)
          ])
          (meta [
            (attrs.itemprop "name")
            (attrs.content pageTitle)
          ])
          (meta [
            (attrs.name "application-name")
            (attrs.content pageTitle)
          ])
          (meta [
            (attrs.property "og:site_name")
            (attrs.content metadata.title)
          ])
          (meta [
            (attrs.property "og:locale")
            (attrs.content metadata.lang)
          ])
          (meta [
            (attrs.property "og:type")
            (attrs.content (if path == [ "index" ] then "website" else "article"))
          ])
        ];

      nav =
        _:
        header
          [
            (attrs.classes [
              "pt-8"
              "pb-12"
            ])
          ]
          [
            (h1
              [
                (attrs.classes [
                  "text-stone-700"
                  "dark:text-stone-300"
                  "text-center"
                  "text-5xl"
                  "font-extralight"
                ])
              ]
              [
                (a [ (attrs.href "/") ] [ metadata.title ])
              ]
            )
          ];

      footer =
        _:
        let
          aClasses = attrs.classes [
            "group"
            "rounded-full"
            "duration-200"
            "border"
            "border-stone-700"
            "dark:border-stone-300"
            "hover:bg-stone-700"
            "dark:hover:bg-stone-300"
          ];
          imgClasses = attrs.classes [
            "h-4"
            "w-4"
            "m-1.5"
            "duration-200"
            "invert-[.20]"
            "group-hover:invert"
            "dark:invert-[.80]"
            "dark:group-hover:invert-[.20]"
          ];
        in
        footer
          [
            (attrs.classes [
              "text-center"
              "text-stone-600"
              "dark:text-stone-400"
            ])
          ]
          [
            (div [ (attrs.classes [ "py-8" ]) ] [ "* * *" ])
            (div
              [
                (attrs.classes [
                  "flex"
                  "flex-row"
                  "justify-center"
                  "gap-4"
                ])
              ]
              [
                # github
                (a
                  [
                    aClasses
                    (attrs.href "https://github.com/${metadata.socials.github}")
                    (attrs.target "_blank")
                  ]
                  [
                    (img [
                      imgClasses
                      (attrs.src "/images/github.svg")
                      (attrs.alt "GitHub Logo")
                    ])
                  ]
                )

                # linkedin
                (a
                  [
                    aClasses
                    (attrs.href "https://www.linkedin.com/in/${metadata.socials.linkedin}")
                    (attrs.target "_blank")
                  ]
                  [
                    (img [
                      imgClasses
                      (attrs.src "/images/linkedin.svg")
                      (attrs.alt "Linkedin Logo")
                    ])
                  ]
                )

                # mastodon
                (a
                  [
                    aClasses
                    (attrs.href metadata.socials.mastodon)
                    (attrs.rel "me")
                  ]
                  [
                    (img [
                      imgClasses
                      (attrs.src "/images/mastodon.svg")
                      (attrs.alt "Mastodon Logo")
                    ])
                  ]
                )

              ]
            )
            (div
              [
                (attrs.classes [
                  "pt-8"
                  "text-sm"
                ])
              ]
              [ metadata.copyright ]
            )
            (div
              [
                (attrs.classes [
                  "py-8"
                  "text-sm"
                ])
              ]
              [
                "This website is generated with "
                (a
                  [
                    (attrs.classes [ "underline" ])
                    (attrs.href "https://github.com/arnarg/nixtml")
                  ]
                  [ "nixtml" ]
                )
              ]
            )
          ];

      post =
        {
          url,
          title,
          date,
          summary,
          ...
        }:
        article
          [
            (attrs.classes [
              "text-stone-700"
              "dark:text-stone-400"
              "max-w-3xl"
              "mb-12"
            ])
          ]
          [
            (header
              [ ]
              [
                (h2
                  [ (attrs.classes [ "my-6" ]) ]
                  [
                    (a
                      [
                        (attrs.classes [
                          "text-stone-700"
                          "hover:text-sky-700"
                          "dark:text-stone-300"
                          "dark:hover:text-sky-300"
                          "no-underline"
                          "!font-light"
                        ])
                        (attrs.href url)
                      ]
                      [ title ]
                    )
                  ]
                )
                (p
                  [
                    (attrs.classes [
                      "mb-2"
                      "text-stone-900"
                      "dark:text-stone-200"
                    ])
                  ]
                  [
                    "Posted on ${date}"
                  ]
                )
              ]
            )
            (div [ ] [ (lib.replaceStrings [ "<p>" "</p>" ] [ "" "" ] summary) ])
            (div
              [
                (attrs.classes [ "my-4" ])
              ]
              [
                (a
                  [
                    (attrs.href url)
                  ]
                  [ (lib.escapeHTML "Read more >") ]
                )
              ]
            )
          ];

      pagination =
        {
          pageNumber,
          totalPages,
          hasPrev,
          prevPageURL,
          hasNext,
          nextPageURL,
          ...
        }:
        div
          [
            (attrs.classes [
              "grid"
              "grid-cols-3"
            ])
          ]
          [
            (
              if hasPrev then
                (div
                  [ (attrs.classes [ "col-start-1" ]) ]
                  [
                    (a
                      [
                        (attrs.classes [ "float-left" ])
                        (attrs.href prevPageURL)
                      ]
                      [
                        (lib.escapeHTML "< Prev")
                      ]
                    )
                  ]
                )
              else
                ""
            )
            (div
              [
                (attrs.classes [
                  "col-start-2"
                  "text-center"
                ])
              ]
              [
                "Page ${toString pageNumber} of ${toString totalPages}"
              ]
            )
            (
              if hasNext then
                (div
                  [ (attrs.classes [ "col-start-3" ]) ]
                  [
                    (a
                      [
                        (attrs.classes [ "float-right" ])
                        (attrs.href nextPageURL)
                      ]
                      [
                        (lib.escapeHTML "Next >")
                      ]
                    )
                  ]
                )
              else
                ""
            )
          ];

      discuss =
        metadata:
        if metadata ? discuss && (metadata.discuss ? hackernews || metadata.discuss ? reddit) then
          (p
            [ ]
            [
              (strong
                [ ]
                [
                  "Discuss on"
                  (
                    if metadata.discuss ? hackernews then
                      (a [ (attrs.href metadata.discuss.hackernews) ] [ "Hacker News" ])
                    else
                      ""
                  )
                  (if metadata.discuss ? hackernews && metadata.discuss ? reddit then " or " else "")
                  (
                    if metadata.discuss ? reddit then (a [ (attrs.href metadata.discuss.reddit) ] [ "Reddit" ]) else ""
                  )
                ]
              )
            ]
          )
        else
          "";
    };
  };

  website.content.processors.md = {
    settings.highlight.style = "gruvbox-dark-medium";
    extraPythonPackages = [
      # Add pygments-styles: https://pygments-styles.org/
      (
        let
          pname = "pygments-styles";
          version = "0.3.0";
        in
        pkgs.python3Packages.buildPythonPackage {
          inherit pname version;
          pyproject = true;

          src = pkgs.fetchFromGitHub {
            owner = "lepture";
            repo = pname;
            rev = version;
            sha256 = "sha256-3tVbeoDCDwHczst9Z22iVBzXfCDoAPjHBYBFzt+CXDY=";
          };

          build-system = with pkgs.python3Packages; [
            setuptools
            setuptools-scm
          ];

          dependencies = with pkgs.python3Packages; [
            setuptools
            pygments
          ];
        }
      )
    ];
  };

  build.extraPackages.stylesheetPackage = pkgs.stdenv.mkDerivation (finalAttrs: {
    name = "nixtml-codedbearder-stylesheet";

    src = ./tailwind;

    yarnOfflineCache = pkgs.fetchYarnDeps {
      yarnLock = finalAttrs.src + "/yarn.lock";
      hash = "sha256-Rh/k0ksHbRpfPbW4LT6gvaxPWKvPq3nnqtl4QnWt2Uk=";
    };

    nativeBuildInputs = with pkgs; [
      yarnConfigHook
      yarnBuildHook
      yarnInstallHook
      # Needed for executing package.json scripts
      nodejs
    ];

    FILES_PACKAGE = config.build.filesPackage;

    buildPhase = ''
      yarn run build
    '';

    installPhase = ''
      mkdir -p $out/css

      mv build/main.css $out/css/main.css
    '';
  });
}
