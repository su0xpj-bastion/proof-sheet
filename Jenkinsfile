// proof-sheet pipeline. Needs a macOS agent labelled 'xcode' (Xcode + simulators + Safari);
// the Linux-capable stages (API + Selenium/Chrome) can run on any agent with Python 3 and Chrome.
// Every stage calls a script in scripts/ci/, the same scripts GitHub Actions runs, so the two never drift.
pipeline {
  agent { label 'xcode' }
  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
    disableConcurrentBuilds()
  }
  parameters {
    booleanParam(name: 'RUN_UI', defaultValue: true, description: 'Run XCUITest on iPhone, iPad and macOS')
    choice(name: 'BROWSER', choices: ['safari', 'chrome', 'ios-safari'], description: 'Selenium browser for the review page')
  }
  environment {
    PROOF_WORK = "${WORKSPACE}/.build/proof-work"
  }
  stages {
    stage('Toolchain') {
      steps {
        sh 'sw_vers && xcodebuild -version && swift --version && python3 --version'
      }
    }
    stage('ProofKit XCTest') {
      steps { sh 'scripts/ci/unit.sh' }
    }
    stage('Cloud API + review page') {
      steps {
        // safaridriver must be enabled once per agent: sudo safaridriver --enable
        sh "PROOF_BROWSER=${params.BROWSER} scripts/ci/web.sh"
      }
      post { always { junit allowEmptyResults: true, testResults: 'build/reports/pytest-*.xml' } }
    }
    stage('XCUITest') {
      when { expression { params.RUN_UI } }
      parallel {
        stage('iPhone') { steps { sh 'scripts/ci/ui.sh ios-iphone' } }
        stage('iPad') { steps { sh 'scripts/ci/ui.sh ios-ipad' } }
        stage('macOS') {
          // Two runs on one agent would fight over the screen: macOS UI tests take a lock.
          steps { lock('mac-ui') { sh 'scripts/ci/ui.sh macos' } }
        }
      }
    }
    stage('Fault matrix + workflow coverage') {
      steps { sh 'scripts/ci/matrix.sh' }
    }
  }
  post {
    always {
      archiveArtifacts allowEmptyArchive: true, artifacts: 'build/reports/**'
      // xcresult bundles open in Xcode; JUnit for the Jenkins test view comes from xcresulttool if installed.
      sh 'for r in build/reports/*.xcresult; do [ -d "$r" ] && xcrun xcresulttool get test-results summary --path "$r" > "$r.summary.json" || true; done'
    }
    failure {
      echo 'Open build/reports/*.xcresult in Xcode for screenshots of each failing UI test.'
    }
  }
}
