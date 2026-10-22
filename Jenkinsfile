// Declarative pipeline for AWS Proj-5 (Docker edition).
// Runs on the Jenkins server (private subnet). Jenkins' process environment is
// pre-populated by scripts/setup_jenkins.sh with: WEB_HOST, DB_HOST, DB_USER,
// DB_NAME, LOG_BUCKET, DOCKERHUB_USER, AWS_DEFAULT_REGION.
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 25, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }

    // Jenkins is in a private subnet, so GitHub webhooks cannot reach it. Poll instead.
    triggers {
        pollSCM('H/2 * * * *')
    }

    environment {
        IMAGE_NAME = 'proj5-webapp'
    }

    stages {
        stage('Lint & Test') {
            steps {
                sh '''
                    python3 -m venv .venv
                    . .venv/bin/activate
                    pip install --quiet --upgrade pip
                    pip install --quiet -r requirements-dev.txt
                    flake8 app tests
                    pytest --junitxml=reports/junit.xml
                '''
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/junit.xml'
                }
            }
        }

        stage('Build Image') {
            steps {
                script {
                    env.APP_VERSION = "${env.BUILD_NUMBER}-${(env.GIT_COMMIT ?: 'local').take(7)}"
                }
                withCredentials([string(credentialsId: 'dockerhub-token', variable: 'DH_TOKEN')]) {
                    sh '''
                        # Log in first: authenticated pulls of the base image get a higher rate limit.
                        echo "$DH_TOKEN" | docker login -u "$DOCKERHUB_USER" --password-stdin
                        IMAGE="$DOCKERHUB_USER/$IMAGE_NAME"
                        docker build --build-arg APP_VERSION="$APP_VERSION" \
                            -t "$IMAGE:$APP_VERSION" -t "$IMAGE:latest" .
                    '''
                }
            }
        }

        stage('Push Image') {
            steps {
                withCredentials([string(credentialsId: 'dockerhub-token', variable: 'DH_TOKEN')]) {
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DOCKERHUB_USER" --password-stdin
                        IMAGE="$DOCKERHUB_USER/$IMAGE_NAME"
                        docker push "$IMAGE:$APP_VERSION"
                        docker push "$IMAGE:latest"
                    '''
                }
            }
        }

        stage('DB Migrate') {
            steps {
                withCredentials([string(credentialsId: 'db-password', variable: 'MYSQL_PWD')]) {
                    sh 'mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < db/schema.sql'
                }
            }
        }

        stage('Deploy') {
            steps {
                sshagent(credentials: ['web-ssh-key']) {
                    sh '''
                        SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
                        scp $SSH_OPTS scripts/deploy.sh ec2-user@"$WEB_HOST":/tmp/deploy.sh
                        ssh $SSH_OPTS ec2-user@"$WEB_HOST" \
                            "bash /tmp/deploy.sh $DOCKERHUB_USER/$IMAGE_NAME:$APP_VERSION"
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh '''
                    for i in $(seq 1 10); do
                        if curl -fsS "http://$WEB_HOST/health" | grep -q "$APP_VERSION"; then
                            echo "Smoke test passed: $APP_VERSION is live"
                            exit 0
                        fi
                        sleep 3
                    done
                    echo "Smoke test failed" >&2
                    exit 1
                '''
            }
        }
    }

    post {
        always {
            script {
                env.BUILD_RESULT = currentBuild.currentResult
            }
            // Remove the registry token from this server and free disk space.
            sh '''
                docker logout || true
                docker image prune -af --filter "until=72h" || true
            '''
            // Ship build metadata, test results and the console log to S3.
            // Note: the console log is copied while the build is still finishing,
            // so the last few lines of this post step may be missing.
            sh '''
                S3_PREFIX="s3://$LOG_BUCKET/$JOB_NAME/$BUILD_NUMBER"
                printf 'job=%s\\nbuild=%s\\nresult=%s\\nversion=%s\\ncommit=%s\\n' \
                    "$JOB_NAME" "$BUILD_NUMBER" "$BUILD_RESULT" \
                    "${APP_VERSION:-n/a}" "${GIT_COMMIT:-n/a}" > build-summary.txt
                aws s3 cp build-summary.txt "$S3_PREFIX/build-summary.txt"
                if [ -f reports/junit.xml ]; then
                    aws s3 cp reports/junit.xml "$S3_PREFIX/junit.xml"
                fi
                LOG="$JENKINS_HOME/jobs/$JOB_NAME/builds/$BUILD_NUMBER/log"
                if [ -f "$LOG" ]; then
                    aws s3 cp "$LOG" "$S3_PREFIX/console.log"
                fi
            '''
        }
    }
}
