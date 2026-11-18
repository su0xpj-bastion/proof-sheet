#!/bin/sh
# Xcode Cloud runs this after cloning (ci_scripts/ is the convention it looks for).
# The project is generated, not committed, so generate it before Xcode Cloud reads the scheme.
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/App" && xcodegen --quiet
