#!/usr/bin/env python3
"""Generate a working Yuyin.xcodeproj with local SPM packages."""
from __future__ import annotations

import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Yuyin.xcodeproj"
SOURCES = sorted((ROOT / "Apps/Yuyin/Sources").glob("*.swift"))


def uid() -> str:
    return uuid.uuid4().hex[:24].upper()


def main() -> None:
    ids = {k: uid() for k in [
        "project", "main_group", "sources_group", "resources_group", "products_group",
        "product_ios", "product_mac",
        "target_ios", "target_mac",
        "src_ios", "src_mac", "fw_ios", "fw_mac", "res_ios", "res_mac",
        "pcl_project", "pcl_ios", "pcl_mac",
        "dbg_p", "rel_p", "dbg_ios", "rel_ios", "dbg_mac", "rel_mac",
        "pkg_core_ref", "pkg_local_ref", "pkg_cloud_ref",
        "prod_core_ios", "prod_local_ios", "prod_cloud_ios",
        "prod_core_mac", "prod_local_mac", "prod_cloud_mac",
        "assets", "assets_ios", "assets_mac", "entitlements", "info",
    ]}

    source_file_ids = {p.name: uid() for p in SOURCES}
    source_build_ios = {p.name: uid() for p in SOURCES}
    source_build_mac = {p.name: uid() for p in SOURCES}

    objects: list[str] = []

    # Build files
    for p in SOURCES:
        objects.append(
            f"\t\t{source_build_ios[p.name]} /* {p.name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {source_file_ids[p.name]} /* {p.name} */; }};"
        )
        objects.append(
            f"\t\t{source_build_mac[p.name]} /* {p.name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {source_file_ids[p.name]} /* {p.name} */; }};"
        )
    objects.append(
        f"\t\t{ids['assets_ios']} /* Assets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {ids['assets']} /* Assets.xcassets */; }};"
    )
    objects.append(
        f"\t\t{ids['assets_mac']} /* Assets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {ids['assets']} /* Assets.xcassets */; }};"
    )

    # File refs
    for p in SOURCES:
        objects.append(
            f'\t\t{source_file_ids[p.name]} /* {p.name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = "Apps/Yuyin/Sources/{p.name}"; '
            f'sourceTree = SOURCE_ROOT; }};'
        )
    objects += [
        f'\t\t{ids["assets"]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "Apps/Yuyin/Resources/Assets.xcassets"; sourceTree = SOURCE_ROOT; }};',
        f'\t\t{ids["entitlements"]} /* Yuyin.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "Apps/Yuyin/Resources/Yuyin.entitlements"; sourceTree = SOURCE_ROOT; }};',
        f'\t\t{ids["info"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Apps/Yuyin/Resources/Info.plist"; sourceTree = SOURCE_ROOT; }};',
        f'\t\t{ids["product_ios"]} /* Yuyin.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Yuyin.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
        f'\t\t{ids["product_mac"]} /* Yuyin.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Yuyin.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
    ]

    # Frameworks phases
    for key in ("fw_ios", "fw_mac"):
        objects.append(
            f"""\t\t{ids[key]} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
        )

    src_children = "\n".join(f"\t\t\t\t{source_file_ids[p.name]} /* {p.name} */," for p in SOURCES)
    objects.append(
        f"""\t\t{ids['main_group']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['sources_group']} /* Sources */,
\t\t\t\t{ids['resources_group']} /* Resources */,
\t\t\t\t{ids['products_group']} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['sources_group']} /* Sources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{src_children}
\t\t\t);
\t\t\tname = Sources;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['resources_group']} /* Resources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['assets']} /* Assets.xcassets */,
\t\t\t\t{ids['entitlements']} /* Yuyin.entitlements */,
\t\t\t\t{ids['info']} /* Info.plist */,
\t\t\t);
\t\t\tname = Resources;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['products_group']} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['product_ios']} /* Yuyin.app */,
\t\t\t\t{ids['product_mac']} /* Yuyin.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};"""
    )

    build_ios = "\n".join(f"\t\t\t\t{source_build_ios[p.name]} /* {p.name} in Sources */," for p in SOURCES)
    build_mac = "\n".join(f"\t\t\t\t{source_build_mac[p.name]} /* {p.name} in Sources */," for p in SOURCES)
    objects.append(
        f"""\t\t{ids['src_ios']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{build_ios}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['src_mac']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{build_mac}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['res_ios']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids['assets_ios']} /* Assets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['res_mac']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids['assets_mac']} /* Assets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
    )

    for target_key, name, product, src, fw, res, pcl, core, local, cloud in [
        ("target_ios", "Yuyin-iOS", "product_ios", "src_ios", "fw_ios", "res_ios", "pcl_ios",
         "prod_core_ios", "prod_local_ios", "prod_cloud_ios"),
        ("target_mac", "Yuyin-macOS", "product_mac", "src_mac", "fw_mac", "res_mac", "pcl_mac",
         "prod_core_mac", "prod_local_mac", "prod_cloud_mac"),
    ]:
        objects.append(
            f"""\t\t{ids[target_key]} /* {name} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids[pcl]} /* Build configuration list for PBXNativeTarget "{name}" */;
\t\t\tbuildPhases = (
\t\t\t\t{ids[src]} /* Sources */,
\t\t\t\t{ids[fw]} /* Frameworks */,
\t\t\t\t{ids[res]} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = "{name}";
\t\t\tpackageProductDependencies = (
\t\t\t\t{ids[core]} /* YuyinCore */,
\t\t\t\t{ids[local]} /* YuyinLocal */,
\t\t\t\t{ids[cloud]} /* YuyinCloud */,
\t\t\t);
\t\t\tproductName = Yuyin;
\t\t\tproductReference = {ids[product]} /* Yuyin.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};"""
        )

    objects.append(
        f"""\t\t{ids['project']} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t}};
\t\t\tbuildConfigurationList = {ids['pcl_project']} /* Build configuration list for PBXProject "Yuyin" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = "zh-Hans";
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t\t"zh-Hans",
\t\t\t);
\t\t\tmainGroup = {ids['main_group']};
\t\t\tpackageReferences = (
\t\t\t\t{ids['pkg_core_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinCore" */,
\t\t\t\t{ids['pkg_local_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinLocal" */,
\t\t\t\t{ids['pkg_cloud_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinCloud" */,
\t\t\t);
\t\t\tproductRefGroup = {ids['products_group']} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{ids['target_ios']} /* Yuyin-iOS */,
\t\t\t\t{ids['target_mac']} /* Yuyin-macOS */,
\t\t\t);
\t\t}};"""
    )

    def cfg(cid: str, name: str, body: str) -> str:
        return f"""\t\t{cid} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{body}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""

    objects.append(cfg(ids["dbg_p"], "Debug", """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 5.0;"""))
    objects.append(cfg(ids["rel_p"], "Release", """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_VERSION = 5.0;"""))

    ios_body = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = Apps/Yuyin/Resources/Yuyin.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Apps/Yuyin/Resources/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.yuyin.client;
\t\t\t\tPRODUCT_NAME = Yuyin;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""
    mac_body = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = Apps/Yuyin/Resources/Yuyin.entitlements;
\t\t\t\tCODE_SIGN_IDENTITY = "-";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = "Apps/Yuyin/Resources/Info-macOS.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.yuyin.client.macos;
\t\t\t\tPRODUCT_NAME = Yuyin;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_VERSION = 5.0;"""
    objects.append(cfg(ids["dbg_ios"], "Debug", ios_body))
    objects.append(cfg(ids["rel_ios"], "Release", ios_body))
    objects.append(cfg(ids["dbg_mac"], "Debug", mac_body))
    objects.append(cfg(ids["rel_mac"], "Release", mac_body))

    def clist(cid: str, label: str, a: str, b: str) -> str:
        return f"""\t\t{cid} /* {label} */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{a} /* Debug */,
\t\t\t\t{b} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};"""

    objects.append(clist(ids["pcl_project"], 'Build configuration list for PBXProject "Yuyin"', ids["dbg_p"], ids["rel_p"]))
    objects.append(clist(ids["pcl_ios"], 'Build configuration list for PBXNativeTarget "Yuyin-iOS"', ids["dbg_ios"], ids["rel_ios"]))
    objects.append(clist(ids["pcl_mac"], 'Build configuration list for PBXNativeTarget "Yuyin-macOS"', ids["dbg_mac"], ids["rel_mac"]))

    objects.append(
        f"""\t\t{ids['pkg_core_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinCore" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/YuyinCore;
\t\t}};
\t\t{ids['pkg_local_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinLocal" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/YuyinLocal;
\t\t}};
\t\t{ids['pkg_cloud_ref']} /* XCLocalSwiftPackageReference "Packages/YuyinCloud" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/YuyinCloud;
\t\t}};"""
    )

    for prod, pkg, name in [
        ("prod_core_ios", "pkg_core_ref", "YuyinCore"),
        ("prod_local_ios", "pkg_local_ref", "YuyinLocal"),
        ("prod_cloud_ios", "pkg_cloud_ref", "YuyinCloud"),
        ("prod_core_mac", "pkg_core_ref", "YuyinCore"),
        ("prod_local_mac", "pkg_local_ref", "YuyinLocal"),
        ("prod_cloud_mac", "pkg_cloud_ref", "YuyinCloud"),
    ]:
        objects.append(
            f"""\t\t{ids[prod]} /* {name} */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {ids[pkg]} /* XCLocalSwiftPackageReference */;
\t\t\tproductName = {name};
\t\t}};"""
        )

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

{chr(10).join(objects)}

	}};
	rootObject = {ids['project']} /* Project object */;
}}
"""
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(pbx)
    ws = PROJECT / "project.xcworkspace"
    ws.mkdir(exist_ok=True)
    (ws / "contents.xcworkspacedata").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""
    )

    # Shared schemes
    schemes = PROJECT / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    for name, tid in [("Yuyin-macOS", ids["target_mac"]), ("Yuyin-iOS", ids["target_ios"])]:
        (schemes / f"{name}.xcscheme").write_text(
            f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
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
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{tid}"
               BuildableName = "Yuyin.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:Yuyin.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
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
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "Yuyin.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Yuyin.xcodeproj">
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
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "Yuyin.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Yuyin.xcodeproj">
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
"""
        )
    print(f"Wrote {PROJECT}")


if __name__ == "__main__":
    main()
