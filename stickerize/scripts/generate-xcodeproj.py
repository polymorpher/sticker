#!/usr/bin/env python3
"""Writes Stickerize.xcodeproj (objectVersion 77, file-system synchronized folders) and its shared scheme.

    python3 scripts/generate-xcodeproj.py .        (run from the stickerize/ folder)

Source files never need this: every target folder is synchronized, so new files are picked up automatically.
Use it only to change targets or build settings from scratch. It overwrites the project, so if you have since
edited the project in Xcode, make the change in Xcode instead. Object IDs are derived from names, so
regenerating an unchanged definition gives an identical file.
"""
import hashlib, os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

def q(v):
    """Quote a pbxproj scalar when needed."""
    s = str(v)
    if s and all(c.isalnum() or c in "._/" for c in s) and not s[0].isdigit() or s.isdigit():
        return s
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def settings_block(d, indent):
    pad = "\t" * indent
    out = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            items = "".join(f"{pad}\t{q(x)},\n" for x in v)
            out.append(f"{pad}{q(k)} = (\n{items}{pad});\n")
        else:
            out.append(f"{pad}{q(k)} = {q(v)};\n")
    return "".join(out)

PACKAGE = oid("pkg.StickerizeKit")
PROJECT = oid("project")

targets = [
    dict(key="app", name="Stickerize", product="Stickerize.app", ftype="wrapper.application",
         ptype="com.apple.product-type.application", groups=["App", "Shared"],
         packages=["StickerizeKit", "StickerLift", "StickerExport"],
         settings={
             "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
             "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
             "CODE_SIGN_ENTITLEMENTS": "Config/AppGroup.entitlements",
             "ENABLE_PREVIEWS": "YES",
             "GENERATE_INFOPLIST_FILE": "YES",
             "INFOPLIST_FILE": "Config/App-Info.plist",
             "INFOPLIST_KEY_CFBundleDisplayName": "Stickerize",
             "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.photography",
             "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "Stickerize saves stickers to your library so you can add them to your iPhone stickers.",
             "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
             "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
             "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
             "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
             "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
             "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX)",
             "PRODUCT_NAME": "$(TARGET_NAME)",
             "SWIFT_EMIT_LOC_STRINGS": "YES",
         }),
    dict(key="msg", name="StickerizeMessages", product="StickerizeMessages.appex", ftype="wrapper.app-extension",
         ptype="com.apple.product-type.app-extension.messages", groups=["MessagesExtension", "ExtensionUI"],
         packages=["StickerizeKit"],
         settings={
             "APPLICATION_EXTENSION_API_ONLY": "YES",
             "ASSETCATALOG_COMPILER_APPICON_NAME": "iMessage App Icon",
             "CODE_SIGN_ENTITLEMENTS": "Config/AppGroup.entitlements",
             "GENERATE_INFOPLIST_FILE": "YES",
             "INFOPLIST_FILE": "Config/Messages-Info.plist",
             "INFOPLIST_KEY_CFBundleDisplayName": "Stickerize",
             "INFOPLIST_KEY_NSStickerSharingLevel": "OS",
             "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
             "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).MessagesExtension",
             "PRODUCT_NAME": "$(TARGET_NAME)",
             "SKIP_INSTALL": "YES",
             "SWIFT_EMIT_LOC_STRINGS": "YES",
         }),
    dict(key="kb", name="StickerizeKeyboard", product="StickerizeKeyboard.appex", ftype="wrapper.app-extension",
         ptype="com.apple.product-type.app-extension", groups=["KeyboardExtension", "ExtensionUI"],
         packages=["StickerizeKit"],
         settings={
             "APPLICATION_EXTENSION_API_ONLY": "YES",
             "CODE_SIGN_ENTITLEMENTS": "Config/AppGroup.entitlements",
             "GENERATE_INFOPLIST_FILE": "YES",
             "INFOPLIST_FILE": "Config/Keyboard-Info.plist",
             "INFOPLIST_KEY_CFBundleDisplayName": "Stickerize",
             "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
             "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).Keyboard",
             "PRODUCT_NAME": "$(TARGET_NAME)",
             "SKIP_INSTALL": "YES",
             "SWIFT_EMIT_LOC_STRINGS": "YES",
         }),
    dict(key="share", name="StickerizeShare", product="StickerizeShare.appex", ftype="wrapper.app-extension",
         ptype="com.apple.product-type.app-extension", groups=["ShareExtension", "Shared"],
         packages=["StickerizeKit", "StickerLift"],
         settings={
             "APPLICATION_EXTENSION_API_ONLY": "YES",
             "CODE_SIGN_ENTITLEMENTS": "Config/AppGroup.entitlements",
             "GENERATE_INFOPLIST_FILE": "YES",
             "INFOPLIST_FILE": "Config/Share-Info.plist",
             "INFOPLIST_KEY_CFBundleDisplayName": "Stickerize",
             "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
             "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).ShareExtension",
             "PRODUCT_NAME": "$(TARGET_NAME)",
             "SKIP_INSTALL": "YES",
             "SWIFT_EMIT_LOC_STRINGS": "YES",
         }),
]
targets.append(dict(key="uitests", name="StickerizeUITests", product="StickerizeUITests.xctest", ftype="wrapper.cfbundle",
         ptype="com.apple.product-type.bundle.ui-testing", groups=["StickerizeUITests"], packages=[],
         settings={
             "GENERATE_INFOPLIST_FILE": "YES",
             "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).UITests",
             "PRODUCT_NAME": "$(TARGET_NAME)",
             "SWIFT_EMIT_LOC_STRINGS": "NO",
             "TEST_TARGET_NAME": "Stickerize",
         }))
extensions = [t for t in targets if t["key"] not in ("app", "uitests")]
uitests = targets[-1]
app = targets[0]

project_common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CODE_SIGN_IDENTITY[sdk=iphonesimulator*]": "-",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "MTL_FAST_MATH": "YES",
}
project_debug = dict(project_common, **{
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
project_release = dict(project_common, **{
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})

XCCONFIG = oid("file.Base.xcconfig")
config_files = ["Base.xcconfig", "AppGroup.entitlements", "App-Info.plist", "Messages-Info.plist", "Keyboard-Info.plist", "Share-Info.plist"]
config_types = {"xcconfig": "text.xcconfig", "entitlements": "text.plist.entitlements", "plist": "text.plist.xml"}
MAIN = oid("group.main")
PRODUCTS = oid("group.products")
CONFIG = oid("group.config")
FRAMEWORKS_GROUP = None
sync_groups = ["App", "Shared", "ExtensionUI", "MessagesExtension", "KeyboardExtension", "ShareExtension", "StickerizeUITests"]
EMBED = oid("phase.embed")

o = []
o.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n")

o.append("\n/* Begin PBXBuildFile section */\n")
for t in targets:
    for p in t["packages"]:
        o.append(f"\t\t{oid('bf.'+t['key']+'.'+p)} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {oid('dep.'+t['key']+'.'+p)} /* {p} */; }};\n")
for t in extensions:
    o.append(f"\t\t{oid('bf.embed.'+t['key'])} /* {t['product']} in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {oid('prod.'+t['key'])} /* {t['product']} */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
o.append("/* End PBXBuildFile section */\n")

o.append("\n/* Begin PBXContainerItemProxy section */\n")
o.append(f"\t\t{oid('proxy.uitests')} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJECT} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {oid('target.app')};\n\t\t\tremoteInfo = Stickerize;\n\t\t}};\n")
for t in extensions:
    o.append(f"\t\t{oid('proxy.'+t['key'])} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJECT} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {oid('target.'+t['key'])};\n\t\t\tremoteInfo = {t['name']};\n\t\t}};\n")
o.append("/* End PBXContainerItemProxy section */\n")

o.append("\n/* Begin PBXCopyFilesBuildPhase section */\n")
files = "".join(f"\t\t\t\t{oid('bf.embed.'+t['key'])} /* {t['product']} in Embed Foundation Extensions */,\n" for t in extensions)
o.append(f"\t\t{EMBED} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\tname = \"Embed Foundation Extensions\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append("/* End PBXCopyFilesBuildPhase section */\n")

o.append("\n/* Begin PBXFileReference section */\n")
for t in targets:
    o.append(f"\t\t{oid('prod.'+t['key'])} /* {t['product']} */ = {{isa = PBXFileReference; explicitFileType = {q(t['ftype'])}; includeInIndex = 0; path = {q(t['product'])}; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for f in config_files:
    ext = f.rsplit(".", 1)[1]
    o.append(f"\t\t{oid('file.'+f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {config_types[ext]}; path = {q(f)}; sourceTree = \"<group>\"; }};\n")
o.append(f"\t\t{oid('file.pkg')} /* StickerizeKit */ = {{isa = PBXFileReference; lastKnownFileType = wrapper; path = StickerizeKit; sourceTree = \"<group>\"; }};\n")
o.append("/* End PBXFileReference section */\n")

o.append("\n/* Begin PBXFileSystemSynchronizedRootGroup section */\n")
for g in sync_groups:
    o.append(f"\t\t{oid('sync.'+g)} /* {g} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {g};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
o.append("/* End PBXFileSystemSynchronizedRootGroup section */\n")

o.append("\n/* Begin PBXFrameworksBuildPhase section */\n")
for t in targets:
    files = "".join(f"\t\t\t\t{oid('bf.'+t['key']+'.'+p)} /* {p} in Frameworks */,\n" for p in t["packages"])
    o.append(f"\t\t{oid('phase.fw.'+t['key'])} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append("/* End PBXFrameworksBuildPhase section */\n")

o.append("\n/* Begin PBXGroup section */\n")
children = "".join(f"\t\t\t\t{oid('sync.'+g)} /* {g} */,\n" for g in sync_groups)
children += f"\t\t\t\t{oid('file.pkg')} /* StickerizeKit */,\n\t\t\t\t{CONFIG} /* Config */,\n\t\t\t\t{PRODUCTS} /* Products */,\n"
o.append(f"\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
children = "".join(f"\t\t\t\t{oid('file.'+f)} /* {f} */,\n" for f in config_files)
o.append(f"\t\t{CONFIG} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
children = "".join(f"\t\t\t\t{oid('prod.'+t['key'])} /* {t['product']} */,\n" for t in targets)
o.append(f"\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
o.append("/* End PBXGroup section */\n")

o.append("\n/* Begin PBXNativeTarget section */\n")
for t in targets:
    phases = [f"{oid('phase.src.'+t['key'])} /* Sources */", f"{oid('phase.fw.'+t['key'])} /* Frameworks */", f"{oid('phase.res.'+t['key'])} /* Resources */"]
    if t is app:
        phases.append(f"{EMBED} /* Embed Foundation Extensions */")
    phases_s = "".join(f"\t\t\t\t{p},\n" for p in phases)
    deps = "".join(f"\t\t\t\t{oid('dep.target.'+e['key'])} /* PBXTargetDependency */,\n" for e in extensions) if t is app else ""
    if t is uitests:
        deps = f"\t\t\t\t{oid('dep.target.uitests')} /* PBXTargetDependency */,\n"
    groups = "".join(f"\t\t\t\t{oid('sync.'+g)} /* {g} */,\n" for g in t["groups"])
    pkgs = "".join(f"\t\t\t\t{oid('dep.'+t['key']+'.'+p)} /* {p} */,\n" for p in t["packages"])
    o.append(f"\t\t{oid('target.'+t['key'])} /* {t['name']} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {oid('cfglist.'+t['key'])} /* Build configuration list for PBXNativeTarget \"{t['name']}\" */;\n\t\t\tbuildPhases = (\n{phases_s}\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{deps}\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n{groups}\t\t\t);\n\t\t\tname = {t['name']};\n\t\t\tpackageProductDependencies = (\n{pkgs}\t\t\t);\n\t\t\tproductName = {t['name']};\n\t\t\tproductReference = {oid('prod.'+t['key'])} /* {t['product']} */;\n\t\t\tproductType = {q(t['ptype'])};\n\t\t}};\n")
o.append("/* End PBXNativeTarget section */\n")

o.append("\n/* Begin PBXProject section */\n")
ta = "".join(f"\t\t\t\t\t{oid('target.'+t['key'])} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.2;\n" + (f"\t\t\t\t\t\tTestTargetID = {oid('target.app')};\n" if t is uitests else "") + "\t\t\t\t\t};\n" for t in targets)
tl = "".join(f"\t\t\t\t{oid('target.'+t['key'])} /* {t['name']} */,\n" for t in targets)
o.append(f"\t\t{PROJECT} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2720;\n\t\t\t\tLastUpgradeCheck = 2720;\n\t\t\t\tTargetAttributes = {{\n{ta}\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {oid('cfglist.project')} /* Build configuration list for PBXProject \"Stickerize\" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t{PACKAGE} /* XCLocalSwiftPackageReference \"StickerizeKit\" */,\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n{tl}\t\t\t);\n\t\t}};\n")
o.append("/* End PBXProject section */\n")

for kind, isa in (("res", "PBXResourcesBuildPhase"), ("src", "PBXSourcesBuildPhase")):
    o.append(f"\n/* Begin {isa} section */\n")
    for t in targets:
        label = "Resources" if kind == "res" else "Sources"
        o.append(f"\t\t{oid('phase.'+kind+'.'+t['key'])} /* {label} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    o.append(f"/* End {isa} section */\n")

o.append("\n/* Begin PBXTargetDependency section */\n")
o.append(f"\t\t{oid('dep.target.uitests')} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {oid('target.app')} /* Stickerize */;\n\t\t\ttargetProxy = {oid('proxy.uitests')} /* PBXContainerItemProxy */;\n\t\t}};\n")
for t in extensions:
    o.append(f"\t\t{oid('dep.target.'+t['key'])} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {oid('target.'+t['key'])} /* {t['name']} */;\n\t\t\ttargetProxy = {oid('proxy.'+t['key'])} /* PBXContainerItemProxy */;\n\t\t}};\n")
o.append("/* End PBXTargetDependency section */\n")

o.append("\n/* Begin XCBuildConfiguration section */\n")
for conf, base in (("Debug", project_debug), ("Release", project_release)):
    o.append(f"\t\t{oid('cfg.project.'+conf)} /* {conf} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = {XCCONFIG} /* Base.xcconfig */;\n\t\t\tbuildSettings = {{\n{settings_block(base, 4)}\t\t\t}};\n\t\t\tname = {conf};\n\t\t}};\n")
for t in targets:
    for conf in ("Debug", "Release"):
        o.append(f"\t\t{oid('cfg.'+t['key']+'.'+conf)} /* {conf} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(t['settings'], 4)}\t\t\t}};\n\t\t\tname = {conf};\n\t\t}};\n")
o.append("/* End XCBuildConfiguration section */\n")

o.append("\n/* Begin XCConfigurationList section */\n")
lists = [("project", 'PBXProject "Stickerize"')] + [(t["key"], f'PBXNativeTarget "{t["name"]}"') for t in targets]
for key, label in lists:
    o.append(f"\t\t{oid('cfglist.'+key)} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{oid('cfg.'+key+'.Debug')} /* Debug */,\n\t\t\t\t{oid('cfg.'+key+'.Release')} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
o.append("/* End XCConfigurationList section */\n")

o.append("\n/* Begin XCLocalSwiftPackageReference section */\n")
o.append(f"\t\t{PACKAGE} /* XCLocalSwiftPackageReference \"StickerizeKit\" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = StickerizeKit;\n\t\t}};\n")
o.append("/* End XCLocalSwiftPackageReference section */\n")

o.append("\n/* Begin XCSwiftPackageProductDependency section */\n")
for t in targets:
    for p in t["packages"]:
        o.append(f"\t\t{oid('dep.'+t['key']+'.'+p)} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {PACKAGE} /* XCLocalSwiftPackageReference \"StickerizeKit\" */;\n\t\t\tproductName = {p};\n\t\t}};\n")
o.append("/* End XCSwiftPackageProductDependency section */\n")

o.append(f"\t}};\n\trootObject = {PROJECT} /* Project object */;\n}}\n")

proj = os.path.join(ROOT, "Stickerize.xcodeproj")
os.makedirs(proj, exist_ok=True)
with open(os.path.join(proj, "project.pbxproj"), "w") as fh:
    fh.write("".join(o))

# Shared scheme: builds the app (and its embedded extensions); tests run the package's test bundles.
APP_REF = f'''BuildableIdentifier = "primary"
               BlueprintIdentifier = "{oid('target.app')}"
               BuildableName = "Stickerize.app"
               BlueprintName = "Stickerize"
               ReferencedContainer = "container:Stickerize.xcodeproj"'''
def test_ref(name):
    return f'''         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{name}"
               BuildableName = "{name}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:StickerizeKit">
            </BuildableReference>
         </TestableReference>
'''
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2720"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               {APP_REF}>
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
{test_ref("StickerizeKitTests")}{test_ref("StickerLiftTests")}{test_ref("StickerExportTests")}         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{oid('target.uitests')}"
               BuildableName = "StickerizeUITests.xctest"
               BlueprintName = "StickerizeUITests"
               ReferencedContainer = "container:Stickerize.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            {APP_REF}>
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            {APP_REF}>
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
schemes = os.path.join(proj, "xcshareddata", "xcschemes")
os.makedirs(schemes, exist_ok=True)
with open(os.path.join(schemes, "Stickerize.xcscheme"), "w") as fh:
    fh.write(scheme)
print("wrote", proj)
