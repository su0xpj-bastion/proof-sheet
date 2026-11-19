// proof-sheet pipeline: build → test → fault matrix → package (delivery).
// Runs on any macOS agent labelled 'macos'. With Xcode it also runs XCTest, XCUITest (iPhone, iPad,
// Mac) and archives the app; on a Command Line Tools-only agent those stages are skipped, visibly.
// Every stage calls a script in scripts/ci/, the same scripts GitHub Actions runs, so the two never drift.
pipeline {
  agent { label 'macos' }
  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
    disableConcurrentBuilds()
  }
  parameters {
    choice(name: 'BROWSER', choices: ['chrome', 'safari', 'ios-safari'], description: 'Selenium browser (safari needs `sudo safaridriver --enable` once per agent)')
    booleanParam(name: 'RUN_UI', defaultValue: true, description: 'Run XCUITest when the agent has Xcode')
  }
  environment {
    PROOF_WORK = "${WORKSPACE}/.build/proof-work"
  }
  stages {
    stage('Toolchain') {
      steps {
        sh 'sw_vers && swift --version && python3 --version'
        script {
          env.HAS_XCODE = sh(script: 'bash -c "source scripts/ci/env.sh && echo \\$HAS_XCODE"', returnStdout: true).trim()
          echo "Xcode on this agent: ${env.HAS_XCODE == '1' ? 'yes' : 'no (Command Line Tools only): Xcode-only stages are skipped'}"
        }
      }
    }
    stage('Build + workflow checks') {
      steps { sh 'scripts/ci/unit.sh' }
    }
    stage('Cloud API + review page') {
      steps { sh "PROOF_BROWSER=${params.BROWSER} scripts/ci/web.sh" }
    }
    stage('XCUITest') {
      when { expression { params.RUN_UI && env.HAS_XCODE == '1' } }
      parallel {
        stage('iPhone') { steps { sh 'scripts/ci/ui.sh ios-iphone' } }
        stage('iPad') { steps { sh 'scripts/ci/ui.sh ios-ipad' } }
        stage('macOS') { steps { lock('mac-ui') { sh 'scripts/ci/ui.sh macos' } } }
      }
    }
    stage('Fault matrix + workflow coverage') {
      steps { sh 'scripts/ci/matrix.sh' }
    }
    stage('Package') {
      steps {
        sh 'scripts/ci/package.sh'
        archiveArtifacts artifacts: 'dist/*.tar.gz, dist/*.sha256', fingerprint: true
      }
    }
  }
  post {
    always {
      junit allowEmptyResults: true, testResults: 'build/reports/*.xml'
      archiveArtifacts allowEmptyArchive: true, artifacts: 'build/reports/**'
    }
  }
}
