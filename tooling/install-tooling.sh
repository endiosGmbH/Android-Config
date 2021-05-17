#!/bin/sh
# This file serves as the only place to setup any required tooling on this local machine.
echo "Script executed from: ${PWD}"
SCRIPTDIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
echo "Script location: ${SCRIPTDIR}"
PROJECTDIR=$(dirname ${SCRIPTDIR})
echo "Project location: ${PROJECTDIR}"

echo "Installing required tooling..."

echo "Copying GIT hook..."
cp -fr ${SCRIPTDIR}/hooks ${PROJECTDIR}/.git
echo "Downloading & setting up ktlint binary...(Machine Password may be asked if ktlint binary is not configured)"
curl -sSLO https://github.com/pinterest/ktlint/releases/download/0.40.0/ktlint &&
  chmod a+x ktlint &&
  sudo mv ktlint /usr/local/bin/
# you can also download ktlint manually from https://github.com/pinterest/ktlint/releases
# another option is "brew install ktlint"
echo "Setting up executables..."
chmod 577 ${PROJECTDIR}/.git/hooks/pre-commit

echo "Installation complete!"