#!/usr/bin/env bash
# =============================================================================
#  setup_cardioai_xcode.sh
#  Run this script once on your Mac to create a valid Xcode project.
#
#  USAGE
#  -----
#  1. Unzip iomt_cardioai_ios_v1.2.0.zip somewhere, e.g. ~/Desktop
#  2. Copy THIS script into the same folder (next to iomt_cardioai_ios/)
#  3. Open Terminal, cd to that folder, then run:
#       chmod +x setup_cardioai_xcode.sh
#       ./setup_cardioai_xcode.sh
#  4. When it finishes, double-click CardioAI.xcodeproj to open in Xcode.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Locate the source folder ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Accept the source folder as an argument, or auto-detect
if [[ "${1:-}" != "" && -d "${1}" ]]; then
    SRC="${1}"
elif [[ -d "${SCRIPT_DIR}/iomt_cardioai_ios" ]]; then
    SRC="${SCRIPT_DIR}/iomt_cardioai_ios"
else
    err "Cannot find iomt_cardioai_ios/ folder. Run this script from the same directory as iomt_cardioai_ios/, or pass the path as an argument: ./setup_cardioai_xcode.sh /path/to/iomt_cardioai_ios"
fi

DEST="${SCRIPT_DIR}/CardioAI"
XCODEPROJ="${DEST}/CardioAI.xcodeproj"

info "Source  : ${SRC}"
info "Output  : ${DEST}"
echo ""

# ── Verify Xcode is installed ─────────────────────────────────────────────────
if ! xcode-select -p &>/dev/null; then
    err "Xcode command-line tools not found. Install Xcode from the App Store first."
fi
log "Xcode found at: $(xcode-select -p)"

# ── Create clean destination ───────────────────────────────────────────────────
if [[ -d "${DEST}" ]]; then
    info "Removing existing ${DEST} ..."
    rm -rf "${DEST}"
fi
mkdir -p "${DEST}"

# ── Copy all Swift source files preserving structure ──────────────────────────
info "Copying source files ..."

copy_swift() {
    local rel="$1"
    local src="${SRC}/${rel}"
    local dst="${DEST}/${rel}"
    if [[ -f "${src}" ]]; then
        mkdir -p "$(dirname "${dst}")"
        cp "${src}" "${dst}"
        log "  ${rel}"
    fi
}

# App entry point
copy_swift "CardioAI/CardioAIApp.swift"

# Core
copy_swift "CardioAI/Core/DependencyContainer.swift"
copy_swift "CardioAI/Core/AppConfiguration.swift"
copy_swift "CardioAI/Core/Stores.swift"

# Auth
copy_swift "CardioAI/Auth/AuthService.swift"

# Network
copy_swift "CardioAI/Network/Protocol/Protocol.swift"
copy_swift "CardioAI/Network/WebSocket/BridgeClient.swift"
copy_swift "CardioAI/Network/REST/APIClient.swift"

# Security
copy_swift "CardioAI/Security/HMACSecurityManager.swift"

# Models
copy_swift "CardioAI/Models/Models.swift"

# UI
copy_swift "CardioAI/UI/RootView.swift"
copy_swift "CardioAI/UI/MainTabView.swift"
copy_swift "CardioAI/UI/Dashboard/DashboardView.swift"
copy_swift "CardioAI/UI/Alerts/AlertsView.swift"
copy_swift "CardioAI/UI/Devices/DevicesView.swift"
copy_swift "CardioAI/UI/Settings/SettingsView.swift"
copy_swift "CardioAI/UI/Auth/SignInView.swift"
copy_swift "CardioAI/UI/DevicePairing/DevicePairingView.swift"

# Services
copy_swift "CardioAI/Services/Keychain/KeychainService.swift"
copy_swift "CardioAI/Services/Notifications/NotificationService.swift"
copy_swift "CardioAI/Services/Health/HealthKitService.swift"
copy_swift "CardioAI/Services/Health/DevicePairingService.swift"

# Tests
copy_swift "CardioAITests/CardioAITests.swift"

# Info.plist
mkdir -p "${DEST}/CardioAI/Supporting Files"
if [[ -f "${SRC}/CardioAI/Supporting Files/Info.plist" ]]; then
    cp "${SRC}/CardioAI/Supporting Files/Info.plist" \
       "${DEST}/CardioAI/Supporting Files/Info.plist"
    log "  CardioAI/Supporting Files/Info.plist"
fi

# README
[[ -f "${SRC}/README.md" ]] && cp "${SRC}/README.md" "${DEST}/README.md"

# ── Create CardioAI.xcodeproj bundle ─────────────────────────────────────────
info "Creating CardioAI.xcodeproj ..."
mkdir -p "${XCODEPROJ}/project.xcworkspace"
mkdir -p "${XCODEPROJ}/xcshareddata/xcschemes"

# ── contents.xcworkspacedata ─────────────────────────────────────────────────
cat > "${XCODEPROJ}/project.xcworkspace/contents.xcworkspacedata" << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
   <FileRef location="self:"></FileRef>
</Workspace>
XML
log "  project.xcworkspace/contents.xcworkspacedata"

# ── CardioAI.xcscheme ─────────────────────────────────────────────────────────
cat > "${XCODEPROJ}/xcshareddata/xcschemes/CardioAI.xcscheme" << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES"
                           buildForProfiling="YES" buildForArchiving="YES"
                           buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary"
               BlueprintIdentifier="AA400001"
               BuildableName="CardioAI.app"
               BlueprintName="CardioAI"
               ReferencedContainer="container:CardioAI.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug"
               selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
               selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"
               shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary"
               BlueprintIdentifier="AA400001"
               BuildableName="CardioAI.app"
               BlueprintName="CardioAI"
               ReferencedContainer="container:CardioAI.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug"
                 selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
                 selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"
                 launchStyle="0"
                 useCustomWorkingDirectory="NO"
                 ignoresPersistentStateOnLaunch="NO"
                 debugDocumentVersioning="YES"
                 allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary"
            BlueprintIdentifier="AA400001"
            BuildableName="CardioAI.app"
            BlueprintName="CardioAI"
            ReferencedContainer="container:CardioAI.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <EnvironmentVariables>
         <EnvironmentVariable key="CARDIOAI_WS_URL"
            value="wss://cardioai.hospital.local/stream" isEnabled="YES"/>
         <EnvironmentVariable key="CARDIOAI_API_URL"
            value="https://cardioai.hospital.local/api" isEnabled="YES"/>
         <EnvironmentVariable key="CARDIOAI_CLIENT_ID"
            value="ios-dev-001" isEnabled="YES"/>
         <EnvironmentVariable key="CARDIOAI_ENVIRONMENT"
            value="development" isEnabled="YES"/>
      </EnvironmentVariables>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release"
                  shouldUseLaunchSchemeArgsEnv="YES"
                  useCustomWorkingDirectory="NO">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary"
            BlueprintIdentifier="AA400001"
            BuildableName="CardioAI.app"
            BlueprintName="CardioAI"
            ReferencedContainer="container:CardioAI.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
XML
log "  xcshareddata/xcschemes/CardioAI.xcscheme"

# ── project.pbxproj ───────────────────────────────────────────────────────────
cat > "${XCODEPROJ}/project.pbxproj" << 'PBXPROJ'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		AA000001 = {isa = PBXBuildFile; fileRef = AA100001; };
		AA000002 = {isa = PBXBuildFile; fileRef = AA100002; };
		AA000003 = {isa = PBXBuildFile; fileRef = AA100003; };
		AA000004 = {isa = PBXBuildFile; fileRef = AA100004; };
		AA000005 = {isa = PBXBuildFile; fileRef = AA100005; };
		AA000006 = {isa = PBXBuildFile; fileRef = AA100006; };
		AA000007 = {isa = PBXBuildFile; fileRef = AA100007; };
		AA000008 = {isa = PBXBuildFile; fileRef = AA100008; };
		AA000009 = {isa = PBXBuildFile; fileRef = AA100009; };
		AA000010 = {isa = PBXBuildFile; fileRef = AA100010; };
		AA000011 = {isa = PBXBuildFile; fileRef = AA100011; };
		AA000012 = {isa = PBXBuildFile; fileRef = AA100012; };
		AA000013 = {isa = PBXBuildFile; fileRef = AA100013; };
		AA000014 = {isa = PBXBuildFile; fileRef = AA100014; };
		AA000015 = {isa = PBXBuildFile; fileRef = AA100015; };
		AA000016 = {isa = PBXBuildFile; fileRef = AA100016; };
		AA000017 = {isa = PBXBuildFile; fileRef = AA100017; };
		AA000018 = {isa = PBXBuildFile; fileRef = AA100018; };
		AA000019 = {isa = PBXBuildFile; fileRef = AA100019; };
		AA000020 = {isa = PBXBuildFile; fileRef = AA100020; };
		AA000021 = {isa = PBXBuildFile; fileRef = AA100021; };
		AA000022 = {isa = PBXBuildFile; fileRef = AA100022; };
		AA000099 = {isa = PBXBuildFile; fileRef = AA100099; };
		AA000030 = {isa = PBXBuildFile; fileRef = AA100030; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		AA100001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CardioAIApp.swift; sourceTree = "<group>"; };
		AA100002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DependencyContainer.swift; sourceTree = "<group>"; };
		AA100003 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppConfiguration.swift; sourceTree = "<group>"; };
		AA100004 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeychainService.swift; sourceTree = "<group>"; };
		AA100005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HMACSecurityManager.swift; sourceTree = "<group>"; };
		AA100006 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Protocol.swift; sourceTree = "<group>"; };
		AA100007 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BridgeClient.swift; sourceTree = "<group>"; };
		AA100008 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = APIClient.swift; sourceTree = "<group>"; };
		AA100009 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Models.swift; sourceTree = "<group>"; };
		AA100010 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Stores.swift; sourceTree = "<group>"; };
		AA100011 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RootView.swift; sourceTree = "<group>"; };
		AA100012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MainTabView.swift; sourceTree = "<group>"; };
		AA100013 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DashboardView.swift; sourceTree = "<group>"; };
		AA100014 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AlertsView.swift; sourceTree = "<group>"; };
		AA100015 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevicesView.swift; sourceTree = "<group>"; };
		AA100016 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsView.swift; sourceTree = "<group>"; };
		AA100017 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationService.swift; sourceTree = "<group>"; };
		AA100018 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HealthKitService.swift; sourceTree = "<group>"; };
		AA100019 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AuthService.swift; sourceTree = "<group>"; };
		AA100020 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevicePairingService.swift; sourceTree = "<group>"; };
		AA100021 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SignInView.swift; sourceTree = "<group>"; };
		AA100022 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevicePairingView.swift; sourceTree = "<group>"; };
		AA100099 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		AA100030 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CardioAITests.swift; sourceTree = "<group>"; };
		AA200001 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CardioAI.app; sourceTree = BUILT_PRODUCTS_DIR; };
		AA200002 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CardioAITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		AA300000 = {
			isa = PBXGroup;
			children = (AA300001, AA300090, AA300099);
			sourceTree = "<group>";
		};
		AA300001 = {
			isa = PBXGroup;
			children = (AA100001, AA300010, AA300011, AA300012, AA300013, AA300014, AA300015, AA300016, AA300017);
			name = CardioAI;
			path = CardioAI;
			sourceTree = "<group>";
		};
		AA300010 = {
			isa = PBXGroup;
			children = (AA100019);
			name = Auth;
			path = Auth;
			sourceTree = "<group>";
		};
		AA300011 = {
			isa = PBXGroup;
			children = (AA100002, AA100003, AA100010);
			name = Core;
			path = Core;
			sourceTree = "<group>";
		};
		AA300012 = {
			isa = PBXGroup;
			children = (AA100006, AA100007, AA100008);
			name = Network;
			path = Network;
			sourceTree = "<group>";
		};
		AA300013 = {
			isa = PBXGroup;
			children = (AA100005);
			name = Security;
			path = Security;
			sourceTree = "<group>";
		};
		AA300014 = {
			isa = PBXGroup;
			children = (AA100009);
			name = Models;
			path = Models;
			sourceTree = "<group>";
		};
		AA300015 = {
			isa = PBXGroup;
			children = (AA100011, AA100012, AA100013, AA100014, AA100015, AA100016, AA100021, AA100022);
			name = UI;
			path = UI;
			sourceTree = "<group>";
		};
		AA300016 = {
			isa = PBXGroup;
			children = (AA100004, AA100017, AA100018, AA100020);
			name = Services;
			path = Services;
			sourceTree = "<group>";
		};
		AA300017 = {
			isa = PBXGroup;
			children = (AA100099);
			name = "Supporting Files";
			path = "Supporting Files";
			sourceTree = "<group>";
		};
		AA300090 = {
			isa = PBXGroup;
			children = (AA100030);
			name = CardioAITests;
			path = CardioAITests;
			sourceTree = "<group>";
		};
		AA300099 = {
			isa = PBXGroup;
			children = (AA200001, AA200002);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		AA400001 = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA500001;
			buildPhases = (AA410001, AA410002, AA410003);
			buildRules = ();
			dependencies = ();
			name = CardioAI;
			productName = CardioAI;
			productReference = AA200001;
			productType = "com.apple.product-type.application";
		};
		AA400002 = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA500003;
			buildPhases = (AA410010);
			buildRules = ();
			dependencies = (AA420001);
			name = CardioAITests;
			productName = CardioAITests;
			productReference = AA200002;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin PBXTargetDependency section */
		AA420001 = {isa = PBXTargetDependency; target = AA400001; };
/* End PBXTargetDependency section */

/* Begin PBXProject section */
		AA600001 = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					AA400001 = {CreatedOnToolsVersion = 15.0;};
					AA400002 = {CreatedOnToolsVersion = 15.0; TestTargetID = AA400001;};
				};
			};
			buildConfigurationList = AA500002;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base);
			mainGroup = AA300000;
			productRefGroup = AA300099;
			projectDirPath = "";
			projectRoot = "";
			targets = (AA400001, AA400002);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		AA410001 = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AA000001, AA000002, AA000003, AA000004, AA000005,
				AA000006, AA000007, AA000008, AA000009, AA000010,
				AA000011, AA000012, AA000013, AA000014, AA000015,
				AA000016, AA000017, AA000018, AA000019, AA000020,
				AA000021, AA000022,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		AA410010 = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (AA000030);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXResourcesBuildPhase section */
		AA410002 = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (AA000099);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		AA410003 = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = ();
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin XCBuildConfiguration section */
		AA510001 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 2;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "CardioAI/Supporting Files/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.cardioai.iomt;
				PRODUCT_NAME = CardioAI;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = 1;
				CARDIOAI_WS_URL = "wss://cardioai.hospital.local/stream";
				CARDIOAI_API_URL = "https://cardioai.hospital.local/api";
				CARDIOAI_CLIENT_ID = "ios-debug-001";
				CARDIOAI_ENVIRONMENT = "development";
			};
			name = Debug;
		};
		AA510002 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 2;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = NO;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "CardioAI/Supporting Files/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.cardioai.iomt;
				PRODUCT_NAME = CardioAI;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = 1;
				CARDIOAI_WS_URL = "wss://cardioai.hospital.local/stream";
				CARDIOAI_API_URL = "https://cardioai.hospital.local/api";
				CARDIOAI_CLIENT_ID = "ios-prod-001";
				CARDIOAI_ENVIRONMENT = "production";
			};
			name = Release;
		};
		AA510003 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 2;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.cardioai.iomt.tests;
				PRODUCT_NAME = CardioAITests;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = 1;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/CardioAI.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CardioAI";
			};
			name = Debug;
		};
		AA510004 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 2;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.cardioai.iomt.tests;
				PRODUCT_NAME = CardioAITests;
				SWIFT_VERSION = 5.9;
				TARGETED_DEVICE_FAMILY = 1;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/CardioAI.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CardioAI";
			};
			name = Release;
		};
		AA520001 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)");
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		AA520002 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		AA500001 = {
			isa = XCConfigurationList;
			buildConfigurations = (AA510001, AA510002);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		AA500002 = {
			isa = XCConfigurationList;
			buildConfigurations = (AA520001, AA520002);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		AA500003 = {
			isa = XCConfigurationList;
			buildConfigurations = (AA510003, AA510004);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

	};
	rootObject = AA600001;
}
PBXPROJ
log "  project.pbxproj"

# ── Set the Xcode UTI so macOS recognises the bundle ─────────────────────────
info "Registering .xcodeproj bundle type with macOS ..."
xattr -w com.apple.FinderInfo \
    "$(printf '%-8s%-8s%-8s%-8s' 'XCPr' 'Xcod' '' '' | head -c 32)" \
    "${XCODEPROJ}" 2>/dev/null || true

# Use SetFile if available (Xcode command-line tools)
if command -v SetFile &>/dev/null; then
    SetFile -t "XCPr" -c "Xcod" "${XCODEPROJ}" 2>/dev/null || true
fi

# ── Validate that Xcode can read the pbxproj ─────────────────────────────────
info "Validating project.pbxproj with plutil ..."
if plutil -lint "${XCODEPROJ}/project.pbxproj" &>/dev/null; then
    log "project.pbxproj is valid"
else
    echo ""
    echo "  plutil reports issues — running xcodebuild -list to check:"
    xcodebuild -project "${XCODEPROJ}" -list 2>&1 | head -20 || true
fi

# ── Open in Xcode ─────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────"
log "Project created at: ${DEST}"
echo ""
echo "  Next steps:"
echo "  1. Open Xcode"
echo "  2. File → Open → select  ${DEST}/CardioAI.xcodeproj"
echo "     OR run:  open '${XCODEPROJ}'"
echo ""
echo "  3. In Xcode: Signing & Capabilities → set your Team"
echo "  4. Cmd+R to build and run on simulator"
echo "──────────────────────────────────────────────────"

# Ask to open now
read -r -p "Open in Xcode now? [Y/n] " yn
if [[ ! "${yn}" =~ ^[Nn]$ ]]; then
    open "${XCODEPROJ}"
fi
