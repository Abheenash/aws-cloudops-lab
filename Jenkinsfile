// The same gates as .github/workflows/ci.yml, expressed for Jenkins.
//
// Why both: GitHub Actions is where this repo actually runs CI. Jenkins is what
// most of the enterprises I'm targeting run, usually on a self-hosted controller
// behind a VPN where a SaaS runner isn't an option. The point of keeping the two
// in the same repo is that the *gates* are the contract and the runner is an
// implementation detail — if these two ever disagree, the pipeline is lying.
pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 20, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
    disableConcurrentBuilds()
  }

  environment {
    // Pinned deliberately — see the note in .github/workflows and the README.
    TF_VERSION  = '1.15.8'
    PYTHON_BIN  = 'python3'
    VENV        = "${WORKSPACE}/.venv"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git --no-pager log -1 --oneline'
      }
    }

    stage('Set up Python') {
      steps {
        sh '''
          set -eu
          "$PYTHON_BIN" -m venv "$VENV"
          "$VENV/bin/pip" install --quiet --upgrade pip
          "$VENV/bin/pip" install --quiet -r tests/requirements.txt
          "$VENV/bin/pip" install --quiet checkov ansible-core ansible-lint
        '''
      }
    }

    // Jenkins' equivalent of independent GitHub jobs. These four have no ordering
    // dependency, so running them serially would just make the build slower.
    stage('Gates') {
      parallel {
        stage('pytest (automation)') {
          steps {
            sh '"$VENV/bin/python" -m pytest tests -q --junitxml=reports/pytest.xml'
          }
          post {
            always { junit allowEmptyResults: true, testResults: 'reports/pytest.xml' }
          }
        }

        stage('terraform fmt + validate') {
          steps {
            sh '''
              set -eu
              terraform -chdir=terraform fmt -check -diff
              terraform -chdir=terraform init -backend=false -input=false
              terraform -chdir=terraform validate
              terraform -chdir=brownfield init -backend=false -input=false
              terraform -chdir=brownfield validate
            '''
          }
        }

        stage('checkov') {
          steps {
            sh '"$VENV/bin/checkov" --config-file .checkov.yaml --quiet --compact'
          }
        }

        stage('ansible-lint') {
          steps {
            sh '''
              set -eu
              cd ansible
              "$VENV/bin/ansible-galaxy" collection install -r requirements.yml -p ./collections
              ANSIBLE_COLLECTIONS_PATH=./collections \
                "$VENV/bin/ansible-lint" playbooks roles --exclude collections
              ANSIBLE_COLLECTIONS_PATH=./collections \
                "$VENV/bin/ansible-playbook" --syntax-check -i localhost, playbooks/site.yml
            '''
          }
        }
      }
    }

    stage('Runbook link check') {
      steps {
        sh '''
          set -eu
          for f in $(grep -ho 'runbooks/[a-z0-9-]*\\.md' terraform/observability.tf | sort -u); do
            test -f "$f" || { echo "missing $f"; exit 1; }
          done
          echo "all alarm runbooks present"
        '''
      }
    }

    // Drift reporting, not drift correction. A pipeline that silently "fixes"
    // production is how you lose the audit trail; this reports and stops.
    stage('Config drift report') {
      when {
        allOf {
          branch 'main'
          expression { return env.COPS_DB_HOST?.trim() }
        }
      }
      steps {
        sh '''
          set -eu
          cd ansible
          ANSIBLE_COLLECTIONS_PATH=./collections \
            "$VENV/bin/ansible-playbook" playbooks/drift-check.yml --check --diff \
            | tee ../reports/drift.txt
        '''
        archiveArtifacts artifacts: 'reports/drift.txt', allowEmptyArchive: true
      }
    }
  }

  post {
    always  { cleanWs(deleteDirs: true, notFailBuild: true) }
    failure { echo 'Gate failed — see the stage above. Nothing was applied.' }
  }
}
