// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NppMacPOC",
    // La UI está en español; el resto de los idiomas caen a este cuando falta
    // una traducción. Agregar un idioma = agregar un <lang>.lproj más abajo.
    defaultLocalization: "es",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CLexilla",
            path: "Sources/CLexilla",
            exclude: ["lexers/LexUser.cxx"],
            sources: ["src/Lexilla.cxx", "lexlib", "lexers", "LexUserStub.cxx"],
            publicHeadersPath: "pubinclude",
            cSettings: [
                .headerSearchPath("hdrs_lexilla"),
                .headerSearchPath("hdrs_scintilla"),
                .headerSearchPath("lexlib")
            ],
            cxxSettings: [
                .headerSearchPath("hdrs_lexilla"),
                .headerSearchPath("hdrs_scintilla"),
                .headerSearchPath("lexlib")
            ]
        ),
        .target(
            name: "CUchardet",
            path: "Sources/CUchardet",
            exclude: [
                "src/Big5Freq.tab", "src/EUCKRFreq.tab", "src/EUCTWFreq.tab",
                "src/GB2312Freq.tab", "src/JISFreq.tab", "src/README.TXT"
            ],
            sources: ["src"],
            publicHeadersPath: "pubinclude",
            cxxSettings: [
                .headerSearchPath("hdrs_uchardet")
            ]
        ),
        .target(
            name: "LexillaShim",
            dependencies: ["CLexilla"],
            path: "Sources/LexillaShim",
            cxxSettings: [
                .headerSearchPath("../CLexilla/hdrs_lexilla"),
                .headerSearchPath("../CLexilla/hdrs_scintilla")
            ]
        ),
        .target(
            name: "CPugixml",
            path: "Sources/CPugixml",
            sources: ["vendor/pugixml.cpp"],
            publicHeadersPath: "pubinclude",
            cxxSettings: [
                .headerSearchPath("vendor")
            ]
        ),
        .target(
            name: "NppDataShim",
            dependencies: ["CPugixml"],
            path: "Sources/NppDataShim",
            cxxSettings: [
                .headerSearchPath("../CPugixml/vendor")
            ]
        ),
        .target(
            name: "Ccmarkgfm",
            path: "Sources/Ccmarkgfm",
            // Tablas generadas que se #incluyen dentro de otros .c — SwiftPM las
            // toma por fuentes y las manda a clang como unidades sueltas si no.
            exclude: ["vendor/src/entities.inc", "vendor/src/case_fold_switch.inc"],
            sources: ["vendor/src", "vendor/extensions"],
            publicHeadersPath: "pubinclude",
            cSettings: [
                .headerSearchPath("vendor/src"),
                .headerSearchPath("vendor/extensions"),
                // Sin CMake no hay librería compartida: las macros de visibilidad
                // de cmark-gfm deben resolverse a vacío o el link estático falla.
                .define("CMARK_GFM_STATIC_DEFINE"),
                .define("CMARK_GFM_EXTENSIONS_STATIC_DEFINE")
            ]
        ),
        .target(
            name: "CmarkShim",
            dependencies: ["Ccmarkgfm"],
            path: "Sources/CmarkShim"
        ),
        .executableTarget(
            name: "NppMacPOC",
            dependencies: ["LexillaShim", "CUchardet", "NppDataShim", "CmarkShim"],
            path: "Sources/NppMacPOC",
            resources: [
                .copy("Resources/langs.model.xml"),
                .copy("Resources/stylers.model.xml"),
                .copy("Resources/DarkModeDefault.xml"),
                .copy("Resources/langs.mac-extra.xml"),
                .copy("Resources/stylers.mac-extra.light.xml"),
                .copy("Resources/stylers.mac-extra.dark.xml"),
                .copy("Resources/markdown-preview.css"),
                .process("Resources/es.lproj"),
                .process("Resources/en.lproj")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-F", "Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "Frameworks",
                    "-framework", "Scintilla",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Frameworks"
                ])
            ]
        )
    ],
    cLanguageStandard: .gnu17,
    cxxLanguageStandard: .cxx17
)
