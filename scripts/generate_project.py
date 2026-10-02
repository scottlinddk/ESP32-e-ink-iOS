#!/usr/bin/env python3
"""Generate a stable, dependency-free Xcode project. Run after adding Swift files.

The checked-in project opens directly in Xcode. This generator needs only Python 3.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "EInk.xcodeproj"


def identifier(value: str) -> str:
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()


def encode(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        entries = [f'{indent}\t{json.dumps(str(k))} = {encode(v, depth + 1)};' for k, v in value.items()]
        return "{\n" + "\n".join(entries) + "\n" + indent + "}"
    if isinstance(value, list):
        return "(\n" + "\n".join(f'{indent}\t{encode(item, depth + 1)},' for item in value) + "\n" + indent + ")"
    return json.dumps(str(value), ensure_ascii=False)


def generate() -> dict[Path, str]:
    objects = {}

    def add(key, isa, **fields):
        uid = identifier(key)
        objects[uid] = {"isa": isa, **fields}
        return uid

    app_id = identifier("target:app")
    test_id = identifier("target:tests")
    project_id = identifier("project")
    clerk_package = add("package:clerk", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/clerk/clerk-ios", requirement={"kind": "exactVersion", "version": "1.5.8"})
    clerk_products = [add("package-product:" + name, "XCSwiftPackageProductDependency", package=clerk_package, productName=name) for name in ["ClerkKit", "ClerkKitUI"]]
    clerk_builds = [add("package-build:" + name, "PBXBuildFile", productRef=ref) for name, ref in zip(["ClerkKit", "ClerkKitUI"], clerk_products)]
    products = [
        add("product:app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="EInk.app", sourceTree="BUILT_PRODUCTS_DIR"),
        add("product:tests", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="EInkTests.xctest", sourceTree="BUILT_PRODUCTS_DIR"),
    ]
    app_sources = sorted(ROOT.glob("EInk/**/*.swift"))
    test_sources = sorted(ROOT.glob("Tests/**/*.swift"))
    assets = sorted(ROOT.glob("EInk/**/*.xcassets"))
    privacy = sorted(ROOT.glob("EInk/**/*.xcprivacy"))
    fixtures = sorted(ROOT.glob("Tests/Fixtures/*.json"))
    phases = {}
    groups = {}
    for target, files, resources in [("app", app_sources, assets + privacy), ("tests", test_sources, fixtures)]:
        children, sources, resource_builds = [], [], []
        for file in files + resources:
            path = file.relative_to(ROOT).as_posix()
            file_type = {".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog", ".xcprivacy": "text.xml", ".json": "text.json"}[file.suffix]
            ref = add("file:" + path, "PBXFileReference", lastKnownFileType=file_type, name=file.name, path=path, sourceTree="SOURCE_ROOT")
            build = add("build:" + path, "PBXBuildFile", fileRef=ref)
            children.append(ref)
            (sources if file.suffix == ".swift" else resource_builds).append(build)
        groups[target] = add("group:" + target, "PBXGroup", children=children, name="EInk" if target == "app" else "Tests", sourceTree="<group>")
        phases[target] = [
            add(f"phase:{target}:sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0),
            add(f"phase:{target}:frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=clerk_builds if target == "app" else [], runOnlyForDeploymentPostprocessing=0),
            add(f"phase:{target}:resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0),
        ]
    config_ref = add("file:info", "PBXFileReference", lastKnownFileType="text.plist.xml", name="Info.plist", path="Config/Info.plist", sourceTree="SOURCE_ROOT")
    simulator_entitlements = add("file:simulator-entitlements", "PBXFileReference", lastKnownFileType="text.plist.entitlements", name="Simulator.entitlements", path="Config/Simulator.entitlements", sourceTree="SOURCE_ROOT")
    config_group = add("group:config", "PBXGroup", children=[config_ref, simulator_entitlements], name="Config", sourceTree="<group>")
    product_group = add("group:products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
    root_group = add("group:root", "PBXGroup", children=[groups["app"], groups["tests"], config_group, product_group], sourceTree="<group>")

    def configuration_list(owner, settings):
        refs = []
        for name in ["Debug", "Release"]:
            values = dict(settings)
            if owner == "project":
                values.update({"DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O"})
                if name == "Debug":
                    values.update({"ENABLE_TESTABILITY": "YES", "ONLY_ACTIVE_ARCH": "YES", "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"], "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)"})
                else:
                    values.update({"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
            refs.append(add(f"config:{owner}:{name}", "XCBuildConfiguration", buildSettings=values, name=name))
        return add("configs:" + owner, "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES", "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR", "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR", "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE", "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic", "MARKETING_VERSION": "1.0.0", "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_IDENTITY[sdk=iphonesimulator*]": "-", "CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]": "YES",
        "CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]": "YES",
    }
    project_configs = configuration_list("project", common)
    app_configs = configuration_list("app", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Config/Info.plist",
        "CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]": "Config/EInk.entitlements",
        "CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]": "Config/Simulator.entitlements",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": "dk.scottlind.eink", "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES", "TARGETED_DEVICE_FAMILY": "1",
    })
    test_configs = configuration_list("tests", {
        "BUNDLE_LOADER": "$(TEST_HOST)", "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": "dk.scottlind.eink.tests", "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "1",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/EInk.app/EInk",
    })
    proxy = add("proxy:app", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_id, remoteInfo="EInk")
    dependency = add("dependency:app", "PBXTargetDependency", target=app_id, targetProxy=proxy)
    for key, name, config, product, target_phases, dependencies, product_type in [
        ("target:app", "EInk", app_configs, products[0], phases["app"], [], "com.apple.product-type.application"),
        ("target:tests", "EInkTests", test_configs, products[1], phases["tests"], [dependency], "com.apple.product-type.bundle.unit-test"),
    ]:
        add(key, "PBXNativeTarget", buildConfigurationList=config, buildPhases=target_phases, buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=product, productType=product_type)
    objects[app_id]["packageProductDependencies"] = clerk_products
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {app_id: {"CreatedOnToolsVersion": "16.0"}, test_id: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_id}}}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "da", "Base"], mainGroup=root_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[app_id, test_id])
    objects[project_id]["packageReferences"] = [clerk_package]
    pbx = "// !$*UTF8*$!\n" + encode({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}) + "\n"
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="EInk.app" BlueprintName="EInk" ReferencedContainer="container:EInk.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="EInkTests.xctest" BlueprintName="EInkTests" ReferencedContainer="container:EInk.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" codeCoverageEnabled="YES">
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="EInkTests.xctest" BlueprintName="EInkTests" ReferencedContainer="container:EInk.xcodeproj"/>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="EInk.app" BlueprintName="EInk" ReferencedContainer="container:EInk.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="EInk.app" BlueprintName="EInk" ReferencedContainer="container:EInk.xcodeproj"/>
    </BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    workspace = '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n'
    return {PROJECT / "project.pbxproj": pbx, PROJECT / "xcshareddata/xcschemes/EInk.xcscheme": scheme, PROJECT / "project.xcworkspace/contents.xcworkspacedata": workspace}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the generated project is stale")
    args = parser.parse_args()
    stale = []
    for file, contents in generate().items():
        if args.check:
            if not file.exists() or file.read_text(encoding="utf-8") != contents:
                stale.append(file.relative_to(ROOT))
        else:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(contents, encoding="utf-8", newline="\n")
    if stale:
        parser.exit(1, f"Stale project files: {', '.join(map(str, stale))}. Run python3 scripts/generate_project.py\n")
    print("Xcode project is current." if args.check else "Generated EInk.xcodeproj.")


if __name__ == "__main__":
    main()
