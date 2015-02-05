#!/bin/sh

##################################################################################
# Custom build tool for Realm Objective C binding.
#
# (C) Copyright 2011-2014 by realm.io.
##################################################################################

# Warning: pipefail is not a POSIX compatible option, but on OS X it works just fine.
#          OS X uses a POSIX complain version of bash as /bin/sh, but apparently it does
#          not strip away this feature. Also, this will fail if somebody forces the script
#          to be run with zsh.
set -o pipefail
set -e

# You can override the version of the core library
# Otherwise, use the default value
if [ -z "$REALM_CORE_VERSION" ]; then
    REALM_CORE_VERSION=0.88.0
fi

# You can override the xcmode used
# Otherwise, use the default value
if [ -z "$XCMODE" ]; then
    XCMODE="xcodebuild"
fi

PATH=/usr/local/bin:/usr/bin:/bin:/usr/libexec:$PATH

if ! [ -z "${JENKINS_HOME}" ]; then
    XCPRETTY_PARAMS="--no-utf --report junit --output build/reports/junit.xml"
    CODESIGN_PARAMS="CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO"
fi

usage() {
cat <<EOF
Usage: sh $0 command [argument]

command:
  download-core:           downloads core library (binary version)
  clean:	           clean up/remove all generated files
  build:                   builds iOS and OS X frameworks
  ios:                     builds iOS frameworks
  ios-dynamic:             builds iOS dynamic frameworks
  ios-static:              builds a fat iOS static framework
  osx:                     builds OS X framework
  test-ios:                tests iOS framework
  test-ios-devices:        tests iOS on all attached iOS devices
  test-osx:                tests OSX framework
  test:                    tests iOS and OS X frameworks
  test-all:                tests iOS and OS X frameworks with debug and release configurations
  examples:                builds all examples in examples/
  browser:                 builds the Realm Browser OSX app
  test-browser:            tests the Realm Browser OSX app
  verify:                  cleans, removes docs/output/, then runs docs, test-all, examples & browser
  docs:                    builds docs in docs/output
  get-version:             get the current version
  set-version version:     set the version

argument:
  xcmode:  xcodebuild (default), xcpretty or xctool
  version: version in the x.y.z format
EOF
}

######################################
# Xcode Helpers
######################################

xcode() {
    mkdir -p build/DerivedData
    CMD="xcodebuild -IDECustomDerivedDataLocation=build/DerivedData $@ $BUILD_SETTINGS"
    echo "Building with command:" $CMD
    eval $CMD
}

xc() {
    if [[ "$XCMODE" == "xcodebuild" ]]; then
        xcode "$@"
    elif [[ "$XCMODE" == "xcpretty" ]]; then
        mkdir -p build
        xcode "$@" | tee build/build.log | xcpretty -c ${XCPRETTY_PARAMS} || {
            echo "The raw xcodebuild output is available in build/build.log"
            exit 1
        }
    elif [[ "$XCMODE" == "xctool" ]]; then
        xctool "$@" "$BUILD_SETTINGS"
    fi
}

xcrealm() {
    PROJECT=Realm.xcodeproj
    xc "-project $PROJECT $@"
}

xcrealmswift() {
    PROJECT=RealmSwift.xcodeproj
    xc "-project $PROJECT $@"
}

build_combined() {
    local scheme="$1"
    local config="$2"
    local module_name="$3"
    local scope_suffix="$4"

    # Derive build paths
    local build_products_path="build/DerivedData/Realm/Build/Products"
    local product_name="$module_name.framework"
    local binary_path="$module_name"
    local iphoneos_path="$build_products_path/$config-iphoneos$scope_suffix/$product_name"
    local iphonesimulator_path="$build_products_path/$config-iphonesimulator$scope_suffix/$product_name"
    local out_path="build/ios"

    # Build for each platform
    xcrealm "-scheme '$scheme' -configuration $config -sdk iphoneos"
    xcrealm "-scheme '$scheme' -configuration $config -sdk iphonesimulator"

    # Combine .swiftmodule
    if [ -d $iphoneos_path/Modules/$module_name.swiftmodule ]; then
      cp $iphoneos_path/Modules/$module_name.swiftmodule/* $iphonesimulator_path/Modules/$module_name.swiftmodule/
    fi

    # Retrieve build products
    local combined_out_path="$out_path"
    if file $iphoneos_path/$binary_path | grep -q "dynamically linked"; then
      combined_out_path="$out_path/simulator"
      clean_retrieve $iphoneos_path        $out_path/iphone    $product_name
      clean_retrieve $iphonesimulator_path $out_path/simulator $product_name
    else
      clean_retrieve $iphoneos_path        $out_path           $product_name
    fi

    # Combine ar archives
    xcrun lipo -create "$iphonesimulator_path/$binary_path" "$iphoneos_path/$binary_path" -output "$combined_out_path/$product_name/$module_name"
}

clean_retrieve() {
  mkdir -p $2
  rm -rf $2/$3
  cp -R $1 $2
}


######################################
# Device Test Helper
######################################

test_ios_devices() {
    serial_numbers_str=$(system_profiler SPUSBDataType | grep "Serial Number: ")
    serial_numbers=()
    while read -r line; do
        number=${line:15} # Serial number starts at position 15
        if [[ ${#number} == 40 ]]; then
            serial_numbers+=("$number")
        fi
    done <<< "$serial_numbers_str"
    if [[ ${#serial_numbers[@]} == 0 ]]; then
        echo "At least one iOS device must be connected to this computer to run device tests"
        if [ -z "${JENKINS_HOME}" ]; then
            # Don't fail if running locally and there's no device
            exit 0
        fi
        exit 1
    fi
    configuration="$1"
    for device in "${serial_numbers[@]}"; do
        xcrealm "-scheme 'iOS Device Tests' -configuration $configuration -destination 'id=$device' test"
    done
    exit 0
}

######################################
# Input Validation
######################################

if [ "$#" -eq 0 -o "$#" -gt 3 ]; then
    usage
    exit 1
fi

######################################
# Variables
######################################

# Xcode sets this variable - set to current directory if running standalone
if [ -z "$SRCROOT" ]; then
    SRCROOT="$(pwd)"
fi

download_core() {
    echo "Downloading dependency: core ${REALM_CORE_VERSION}"
    TMP_DIR="/tmp/core_bin"
    mkdir -p "${TMP_DIR}"
    CORE_TMP_ZIP="${TMP_DIR}/core-${REALM_CORE_VERSION}.zip.tmp"
    CORE_ZIP="${TMP_DIR}/core-${REALM_CORE_VERSION}.zip"
    if [ ! -f "${CORE_ZIP}" ]; then
        curl -L -s "http://static.realm.io/downloads/core/realm-core-${REALM_CORE_VERSION}.zip" -o "${CORE_TMP_ZIP}"
        mv "${CORE_TMP_ZIP}" "${CORE_ZIP}"
    fi
    (
        cd "${TMP_DIR}"
        rm -rf core
        unzip "${CORE_ZIP}"
        mv core core-${REALM_CORE_VERSION}
    )

    rm -rf core-${REALM_CORE_VERSION} core
    mv ${TMP_DIR}/core-${REALM_CORE_VERSION} .
    ln -s core-${REALM_CORE_VERSION} core
}

COMMAND="$1"
CONFIGURATION="$2"
BUILD_SETTINGS="$3"
: ${XCMODE:=xcodebuild} # must be one of: xcodebuild (default), xcpretty, xctool

# Default to Release configuration
if [ -z "$CONFIGURATION" ]; then
    CONFIGURATION="Release"
fi
    
case "$COMMAND" in

    ######################################
    # Clean
    ######################################
    "clean")
        find . -type d -name build -exec rm -r "{}" +\;
        exit 0
        ;;

    ######################################
    # Download Core Library
    ######################################
    "download-core")
        if [ "$REALM_CORE_VERSION" = "current" ]; then
            echo "Using version of core already in core/ directory"
            exit 0
        fi
        if [ -d core -a -d ../tightdb -a ! -L core ]; then
          # Allow newer versions than expected for local builds as testing
          # with unreleased versions is one of the reasons to use a local build
          if ! $(grep -i "${REALM_CORE_VERSION} Release notes" core/release_notes.txt >/dev/null); then
              echo "Local build of core is out of date."
              exit 1
          else
              echo "The core library seems to be up to date."
          fi
        elif ! [ -L core ]; then
            echo "core is not a symlink. Deleting..."
            rm -rf core
            download_core
        elif ! $(head -n 1 core/release_notes.txt | grep -i ${REALM_CORE_VERSION} >/dev/null); then
            download_core
        else
            echo "The core library seems to be up to date."
        fi
        exit 0
        ;;

    ######################################
    # Building
    ######################################
    "build")
        sh build.sh ios $CONFIGURATION
        sh build.sh osx $CONFIGURATION
        exit 0
        ;;

    "ios")
        sh build.sh ios-static $CONFIGURATION
        exit 0
        ;;

    "ios-dynamic")
        xcrealm "-scheme 'iOS Dynamic' -configuration $CONFIGURATION build -sdk iphoneos"
        xcrealm "-scheme 'iOS Dynamic' -configuration $CONFIGURATION build -sdk iphonesimulator -destination 'name=iPhone 6'"
        exit 0
        ;;

    "ios-swift")
        xcrealmswift "-scheme 'RealmSwift iOS' -configuration $CONFIGURATION build -sdk iphoneos"
        xcrealmswift "-scheme 'RealmSwift iOS' -configuration $CONFIGURATION build -sdk iphonesimulator -destination 'name=iPhone 6'"
        exit 0
        ;;

    "ios-static")
        build_combined iOS $CONFIGURATION Realm
        exit 0
        ;;

    "osx")
        xcrealm "-scheme OSX -configuration $CONFIGURATION"
        exit 0
        ;;

    "osx-swift")
        xcrealmswift "-scheme 'RealmSwift OSX' -configuration $CONFIGURATION"
        exit 0
        ;;

    ######################################
    # Testing
    ######################################
    "test")
        set +e # Run both sets of tests even if the first fails
        failed=0
        sh build.sh test-ios $CONFIGURATION || failed=1
        sh build.sh test-ios-dynamic $CONFIGURATION || failed=1
        sh build.sh test-ios-swift $CONFIGURATION || failed=1
        sh build.sh test-ios-devices $CONFIGURATION || failed=1
        sh build.sh test-osx $CONFIGURATION || failed=1
        sh build.sh test-osx-swift $CONFIGURATION || failed=1
        exit $failed
        ;;

    "test-all")
        set +e
        failed=0
        sh build.sh test Release || failed=1
        sh build.sh test Debug || failed=1
        exit $failed
        ;;

    "test-ios")
        xcrealm "-scheme iOS -configuration $CONFIGURATION -sdk iphonesimulator -destination 'name=iPhone 6' test"
        xcrealm "-scheme iOS -configuration $CONFIGURATION -sdk iphonesimulator -destination 'name=iPhone 4S' test"
        exit 0
        ;;

    "test-ios-dynamic")
        xcrealm "-scheme 'iOS Dynamic' -configuration $CONFIGURATION -sdk iphonesimulator -destination 'name=iPhone 6' test"
        exit 0
        ;;

    "test-ios-swift")
        xcrealmswift "-scheme 'RealmSwift iOS' -configuration $CONFIGURATION -sdk iphonesimulator -destination 'name=iPhone 6' test"
        exit 0
        ;;

    "test-ios-devices")
        test_ios_devices $CONFIGURATION 
        ;;

    "test-osx")
        xcrealm "-scheme OSX -configuration $CONFIGURATION test"
        exit 0
        ;;

    "test-osx-swift")
        xcrealmswift "-scheme 'RealmSwift OSX' -configuration $CONFIGURATION test"
        exit 0
        ;;

    "test-cover")
        echo "Not yet implemented"
        exit 0
        ;;

    "verify")
        sh build.sh docs
        sh build.sh test-all 
        sh build.sh examples 
        sh build.sh browser 
        sh build.sh test-browser 

        (
            cd examples/osx/objc/build/DerivedData/RealmExamples/Build/Products/Release
            DYLD_FRAMEWORK_PATH=. ./JSONImport
        ) || exit 1

        exit 0
        ;;

    ######################################
    # Docs
    ######################################
    "docs")
        sh scripts/build-docs.sh
        exit 0
        ;;

    ######################################
    # Examples
    ######################################
    "examples")
        sh build.sh clean

        xc "-project examples/ios/objc/RealmExamples.xcodeproj -scheme Simple -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/objc/RealmExamples.xcodeproj -scheme TableView -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/objc/RealmExamples.xcodeproj -scheme Migration -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/objc/RealmExamples.xcodeproj -scheme Backlink -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/objc/RealmExamples.xcodeproj -scheme GroupedTableView -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/osx/objc/RealmExamples.xcodeproj -scheme JSONImport -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme Simple -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme TableView -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme Migration -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme Encryption -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme Backlink -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        xc "-project examples/ios/swift/RealmExamples.xcodeproj -scheme GroupedTableView -configuration $CONFIGURATION build ${CODESIGN_PARAMS}"
        exit 0
        ;;

    ######################################
    # Browser
    ######################################
    "browser")
        xc "-project tools/RealmBrowser/RealmBrowser.xcodeproj -scheme RealmBrowser -configuration Release clean build ${CODESIGN_PARAMS}"
        exit 0
        ;;

    "test-browser")
        xc "-project tools/RealmBrowser/RealmBrowser.xcodeproj -scheme RealmBrowser test ${CODESIGN_PARAMS}"
        exit 0
        ;;

    ######################################
    # Versioning
    ######################################
    "get-version")
        version_file="Realm/Realm-Info.plist"
        echo "$(PlistBuddy -c "Print :CFBundleVersion" "$version_file")"
        exit 0
        ;;

    "set-version")
        realm_version="$2"
        version_files="Realm/Realm-Info.plist tools/RealmBrowser/RealmBrowser/RealmBrowser-Info.plist"

        if [ -z "$realm_version" ]; then
            echo "You must specify a version."
            exit 1
        fi
        for version_file in $version_files; do
            PlistBuddy -c "Set :CFBundleVersion $realm_version" "$version_file"
            PlistBuddy -c "Set :CFBundleShortVersionString $realm_version" "$version_file"
        done
        exit 0
        ;;

    ######################################
    # CocoaPods
    ######################################
    "cocoapods-setup")
        sh build.sh download-core

        # CocoaPods seems to not like symlinks
        mv core tmp
        mv $(readlink tmp) core
        rm tmp

        # CocoaPods doesn't support multiple header_mappings_dir, so combine
        # both sets of headers into a single directory
        rm -rf include
        mv core/include include
        mkdir -p include/Realm
        cp Realm/*.h include/Realm
        touch include/Realm/RLMPlatform.h
        ;;

    ######################################
    # Release packaging
    ######################################
    "package-browser")
        cd tightdb_objc
        sh build.sh browser
        cd ${WORKSPACE}/tightdb_objc/tools/RealmBrowser/build/DerivedData/RealmBrowser/Build/Products/Release
        zip -r realm-browser.zip Realm\ Browser.app
        mv realm-browser.zip ${WORKSPACE}
        ;;

    "package-docs")
        cd tightdb_objc
        sh build.sh docs
        cd docs/output/*
        tar --exclude='realm-docset.tgz' \
            --exclude='realm.xar' \
            -cvzf \
            realm-docs.tgz *
        ;;

    "package-examples")
        cd tightdb_objc
        ./scripts/package_examples.rb
        zip --symlinks -r realm-obj-examples.zip examples
        ;;

    "package-test-examples")
        VERSION=$(file realm-cocoa-*.zip | grep -o '\d*\.\d*\.\d*')
        unzip realm-cocoa-*.zip

        cp $0 realm-cocoa-${VERSION}
        cd realm-cocoa-${VERSION}
        sh build.sh examples
        cd ..
        rm -rf realm-cocoa-*
        ;;

    "package-ios")
        cd tightdb_objc
        sh build.sh test-ios
        sh build.sh examples
        sh build.sh ios

        cd build/ios
        zip --symlinks -r realm-framework-ios.zip Realm*
        ;;

    "package-osx")
        cd tightdb_objc
        sh build.sh test-osx

        cd build/DerivedData/Realm/Build/Products/Release
        zip --symlinks -r realm-framework-osx.zip Realm.framework
        ;;

    "package-release")
        TEMPDIR=$(mktemp -d /tmp/realm-release-package.XXXX)

        cd tightdb_objc
        VERSION=$(sh build.sh get-version)
        cd ..

        mkdir -p ${TEMPDIR}/realm-cocoa-${VERSION}/osx
        mkdir -p ${TEMPDIR}/realm-cocoa-${VERSION}/ios
        mkdir -p ${TEMPDIR}/realm-cocoa-${VERSION}/browser

        (
            cd ${TEMPDIR}/realm-cocoa-${VERSION}/osx
            unzip ${WORKSPACE}/realm-framework-osx.zip
        )

        (
            cd ${TEMPDIR}/realm-cocoa-${VERSION}/ios
            unzip ${WORKSPACE}/realm-framework-ios.zip
        )

        (
            cd ${TEMPDIR}/realm-cocoa-${VERSION}/browser
            unzip ${WORKSPACE}/realm-browser.zip
        )

        (
            cd ${TEMPDIR}/realm-cocoa-${VERSION}
            unzip ${WORKSPACE}/realm-obj-examples.zip
        )

        cp -R ${WORKSPACE}/tightdb_objc/plugin ${TEMPDIR}/realm-cocoa-${VERSION}
        cp ${WORKSPACE}/tightdb_objc/LICENSE ${TEMPDIR}/realm-cocoa-${VERSION}/LICENSE.txt
        mkdir -p ${TEMPDIR}/realm-cocoa-${VERSION}/Swift
        cp ${WORKSPACE}/tightdb_objc/Realm/Swift/RLMSupport.swift ${TEMPDIR}/realm-cocoa-${VERSION}/Swift/

        cat > ${TEMPDIR}/realm-cocoa-${VERSION}/docs.webloc <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>URL</key>
    <string>http://realm.io/docs/ios/latest</string>
</dict>
</plist>
EOF

        (
          cd ${TEMPDIR}
          zip --symlinks -r realm-cocoa-${VERSION}.zip realm-cocoa-${VERSION}
          mv realm-cocoa-${VERSION}.zip ${WORKSPACE}
        )
        ;;

    "test-package-release")
        # Generate a release package locally for testing purposes
        # Real releases should always be done via Jenkins
        if [ -z "${WORKSPACE}" ]; then
            echo 'WORKSPACE must be set to a directory to assemble the release in'
            exit 1
        fi
        if [ -d "${WORKSPACE}" ]; then
            echo 'WORKSPACE directory should not already exist'
            exit 1
        fi

        REALM_SOURCE=$(pwd)
        mkdir $WORKSPACE
        cd $WORKSPACE
        git clone $REALM_SOURCE tightdb_objc

        echo 'Packaging iOS'
        sh tightdb_objc/build.sh package-ios
        cp tightdb_objc/build/ios/realm-framework-ios.zip .

        echo 'Packaging OS X'
        sh tightdb_objc/build.sh package-osx
        cp tightdb_objc/build/DerivedData/Realm/Build/Products/Release/realm-framework-osx.zip .

        echo 'Packaging docs'
        sh tightdb_objc/build.sh package-docs
        cp tightdb_objc/docs/output/*/realm-docs.tgz .

        echo 'Packaging examples'
        cd tightdb_objc/examples
        git clean -xfd
        cd ../..

        sh tightdb_objc/build.sh package-examples
        cp tightdb_objc/realm-obj-examples.zip .

        echo 'Packaging browser'
        sh tightdb_objc/build.sh package-browser

        echo 'Building final release package'
        sh tightdb_objc/build.sh package-release

        echo 'Testing packaged examples'
        sh tightdb_objc/build.sh package-test-examples

        ;;

    *)
        usage
        exit 1
        ;;
esac
