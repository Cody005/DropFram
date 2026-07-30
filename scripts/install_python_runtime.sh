#!/bin/sh
set -e

SIGNING_IDENTITY=$(echo "${EXPANDED_CODE_SIGN_IDENTITY:-}" | tr -d '[:space:]')
if [ -z "$SIGNING_IDENTITY" ]; then
  export EXPANDED_CODE_SIGN_IDENTITY="-"
  export EXPANDED_CODE_SIGN_IDENTITY_NAME="ad hoc"
fi

source "$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh"

PACKAGE_SOURCE="$PROJECT_DIR/DropFrame/Resources/python-packages"
PACKAGE_DESTINATION="$CODESIGNING_FOLDER_PATH/python-packages"

mkdir -p "$PACKAGE_DESTINATION"
rsync -au --delete "$PACKAGE_SOURCE/" "$PACKAGE_DESTINATION/"

install_python Frameworks/Python.xcframework python-packages
