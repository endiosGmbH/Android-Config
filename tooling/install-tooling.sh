#!/bin/sh
echo "Versioned tooling required for local machine."
echo "Script executed from: ${PWD}"

echo "Installing required tooling..."

# ktlint
echo "Downloading & setting up ktlint binary...(Machine's User Password may be asked once if ktlint binary is not configured)"
# downloading the ktlint binary, marking it as executable and then moving it into the required directory
curl -sSLO https://github.com/pinterest/ktlint/releases/download/0.40.0/ktlint &&
  chmod a+x ktlint &&
  sudo mv -f ktlint /usr/local/bin/
# you can also download ktlint binary manually from https://github.com/pinterest/ktlint/releases
# another option is "brew install ktlint". Refer: https://github.com/pinterest/ktlint#installation

# detekt
echo "Downloading & setting up detekt binary...(Machine's User Password may be asked once if detekt binary is not configured)"
# downloading the detekt archive and unzipping into the required directory
curl -sSLO https://github.com/detekt/detekt/releases/download/v1.22.0/detekt-cli-1.22.0.zip &&
  unzip -o detekt-cli-1.22.0.zip -d /usr/local/bin/
# removing detekt archive file since it is no longer required
rm -f detekt-cli-1.22.0.zip
# marking detekt cli as executable
chmod a+x /usr/local/bin/detekt-cli-1.22.0/bin/detekt-cli
# you can also download detekt binary manually from https://github.com/detekt/detekt/releases
# another option is "brew install detekt". Refer: https://detekt.github.io/detekt/cli.html#macos-with-homebrew

echo "Installation complete!"
