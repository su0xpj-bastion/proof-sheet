#!/bin/bash
# Stand up a local Jenkins (LTS) on this Mac with the proof-sheet pipeline job, bound to 127.0.0.1.
# Everything lives in $JENKINS_DIR (default ~/jenkins-local): Jenkins, its plugins, and a JDK 21
# used only by Jenkins (Jenkins 2.5xx needs Java 21+). No system-wide install, no sudo.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
J=${JENKINS_DIR:-$HOME/jenkins-local}
mkdir -p "$J/home/plugins" "$J/home/init.groovy.d"
cd "$J"
[ -f jenkins.war ] || curl -fsSL -o jenkins.war https://get.jenkins.io/war-stable/latest/jenkins.war
if [ ! -x jdk/Contents/Home/bin/java ]; then
  curl -fsSL -o jdk21.tar.gz "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jdk/hotspot/normal/eclipse"
  mkdir -p jdk && tar -xzf jdk21.tar.gz -C jdk --strip-components=1 && rm jdk21.tar.gz
fi
JAVA=$J/jdk/Contents/Home/bin/java
if [ ! -f pim.jar ]; then
  curl -fsSL -o pim.jar https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.16.0/jenkins-plugin-manager-2.16.0.jar
fi
"$JAVA" -jar pim.jar --war jenkins.war --plugin-download-directory home/plugins \
  --plugins workflow-aggregator git junit timestamper lockable-resources pipeline-stage-view pipeline-graph-view
cp "$HERE/setup.groovy" home/init.groovy.d/setup.groovy
echo "Jenkins: http://127.0.0.1:8080/job/proof-sheet/  (Ctrl-C to stop)"
# Unsecured on purpose: bound to localhost only, for a single developer machine.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" JENKINS_HOME="$J/home" exec "$JAVA" \
  -Djenkins.install.runSetupWizard=false -Djava.awt.headless=true -jar jenkins.war \
  --httpListenAddress=127.0.0.1 --httpPort=8080
