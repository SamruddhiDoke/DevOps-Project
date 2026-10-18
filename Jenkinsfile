// Order & Inventory CI/CD
// GitHub -> tests -> SonarQube quality gate -> Docker build -> Trivy security gates -> ECR
//        -> Helm deploy to EKS (auto-rollback) -> health verification -> rollback on failure
//
// Agent requirements: the toolchain in ci/jenkins/Dockerfile (same versions on the EC2 host via
// ansible/). AWS access comes from the instance role; no AWS keys are stored in Jenkins.
// Optional: SONAR_HOST_URL (+ credential "sonarqube-token") enables the quality-gate stage;
//           CI_REPORTS_BUCKET archives reports to S3 (terraform output ci_reports_bucket).

pipeline {

    agent any

    parameters {
        booleanParam(
            name: 'DEPLOY',
            defaultValue: true,
            description: 'Push images to ECR and deploy to EKS. Disable for CI-only runs (e.g. the local Jenkins).'
        )
        booleanParam(
            name: 'FULL_SMOKE_TEST',
            defaultValue: false,
            description: 'Run the read/write smoke test against the public ALB (creates and cancels a test order). Default is read-only.'
        )
    }

    environment {
        AWS_REGION    = 'ap-south-1'
        APP_DIR       = 'order-inventory-platform'
        EKS_CLUSTER   = 'order-inventory-eks'
        K8S_NAMESPACE = 'order-inventory'
        HELM_RELEASE  = 'order-inventory'
        REPORTS       = "${WORKSPACE}/reports"
        // Trivy vulnerability database cache shared between builds
        TRIVY_CACHE_DIR = "${JENKINS_HOME}/.cache/trivy"
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
        timestamps()
    }

    stages {

        // =========================================================
        // 1. CHECKOUT
        // =========================================================
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    // Immutable, traceable image tag: <build number>-<short commit>
                    env.GIT_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                }
                sh '''
                    set -e
                    echo "Commit ${GIT_SHORT} on ${GIT_BRANCH:-unknown} -> image tag ${IMAGE_TAG}"
                    # Fail fast if the application sources are missing from the checkout
                    for f in ${APP_DIR}/backend/pom.xml ${APP_DIR}/backend/Dockerfile \
                             ${APP_DIR}/frontend/package-lock.json ${APP_DIR}/frontend/Dockerfile \
                             helm/order-inventory/Chart.yaml scripts/deploy-k8s.sh; do
                        test -f "$f" || { echo "Missing required file: $f"; exit 1; }
                    done
                    rm -rf "${REPORTS}" && mkdir -p "${REPORTS}"
                '''
            }
        }

        // =========================================================
        // 2. ENVIRONMENT CHECK
        // =========================================================
        stage('Environment Check') {
            steps {
                sh '''
                    set -e
                    java -version 2>&1 | head -1
                    mvn -version | head -1
                    node --version && npm --version
                    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if (a < 20 || (a === 20 && b < 19)) { console.error("Node >= 20.19 required"); process.exit(1) }'
                    docker --version
                    trivy --version | head -1
                    helm version --short
                    kubectl version --client | head -1
                    aws --version
                '''
            }
        }

        // =========================================================
        // 3. BACKEND TESTS + COVERAGE
        // =========================================================
        stage('Backend Tests') {
            steps {
                dir("${APP_DIR}/backend") {
                    sh 'mvn -B clean verify'
                }
            }
            post {
                always {
                    // allowEmptyResults: false -> a run that executes zero tests is a failure
                    junit(testResults: "${APP_DIR}/backend/target/surefire-reports/*.xml", allowEmptyResults: false)
                    recordCoverage(tools: [[parser: 'JACOCO', pattern: "${APP_DIR}/backend/target/site/jacoco/jacoco.xml"]],
                                   sourceDirectories: [[path: "${APP_DIR}/backend/src/main/java"]],
                                   id: 'backend-coverage', name: 'Backend coverage')
                    sh 'cp -r ${APP_DIR}/backend/target/site/jacoco "${REPORTS}/backend-coverage" 2>/dev/null || true'
                }
            }
        }

        // =========================================================
        // 4. FRONTEND LINT, TESTS + BUILD
        // =========================================================
        stage('Frontend Build') {
            steps {
                dir("${APP_DIR}/frontend") {
                    sh '''
                        set -e
                        npm ci --no-audit --no-fund
                        npm run lint
                        npx vitest run --coverage --reporter=default --reporter=junit --outputFile.junit=reports/junit.xml
                        npm run build
                    '''
                }
            }
            post {
                always {
                    junit(testResults: "${APP_DIR}/frontend/reports/junit.xml", allowEmptyResults: false)
                    sh 'cp -r ${APP_DIR}/frontend/coverage "${REPORTS}/frontend-coverage" 2>/dev/null || true'
                }
            }
        }

        // =========================================================
        // 5. CODE QUALITY (SonarQube quality gate)
        // =========================================================
        stage('Code Quality') {
            when {
                expression {
                    if (!env.SONAR_HOST_URL) {
                        echo 'SONAR_HOST_URL is not configured: SonarQube analysis SKIPPED (see docs/RUNBOOKS.md "SonarQube").'
                        return false
                    }
                    return true
                }
            }
            steps {
                withCredentials([string(credentialsId: 'sonarqube-token', variable: 'SONAR_TOKEN')]) {
                    dir("${APP_DIR}/backend") {
                        // Coverage comes from the JaCoCo report produced in the Backend Tests stage
                        sh 'mvn -B org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211:sonar -Dsonar.host.url=${SONAR_HOST_URL} -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=300'
                    }
                    dir("${APP_DIR}/frontend") {
                        sh 'sonar-scanner -Dsonar.host.url=${SONAR_HOST_URL} -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=300'
                    }
                }
            }
        }

        // =========================================================
        // 6. DEPENDENCY + IaC SECURITY SCAN (gate: CRITICAL deps, HIGH/CRITICAL misconfig)
        // =========================================================
        stage('Dependency & IaC Scan') {
            steps {
                sh '''
                    set -e
                    # Dependency vulnerabilities from lock files (pom.xml, package-lock.json)
                    trivy fs --scanners vuln --skip-dirs '**/node_modules' --format table \
                        --output "${REPORTS}/trivy-dependencies.txt" ${APP_DIR}
                    trivy fs --scanners vuln --skip-dirs '**/node_modules' --severity CRITICAL --exit-code 1 --quiet ${APP_DIR}

                    # Terraform/Helm/Dockerfile misconfigurations. Accepted findings are listed with
                    # their justification in .trivyignore; anything new fails the build.
                    trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore.yaml \
                        --tf-vars terraform/environments/full.tfvars \
                        --skip-dirs '**/node_modules' --skip-dirs terraform/.terraform --skip-dirs k8s/testing \
                        --format table --output "${REPORTS}/trivy-iac.txt" .

                    # Secrets accidentally committed to the working tree
                    trivy fs --scanners secret --skip-dirs '**/node_modules' --exit-code 1 --quiet .
                '''
            }
        }

        // =========================================================
        // 7. HELM CHART VALIDATION
        // =========================================================
        stage('Helm Lint') {
            steps {
                sh '''
                    set -e
                    helm lint helm/order-inventory --strict --set image.tag=${IMAGE_TAG} --set image.registry=example.invalid
                    helm template order-inventory helm/order-inventory -n ${K8S_NAMESPACE} \
                        --set image.tag=${IMAGE_TAG} --set image.registry=example.invalid > "${REPORTS}/rendered-manifests.yaml"
                '''
            }
        }

        // =========================================================
        // 8. DOCKER BUILD
        // =========================================================
        stage('Docker Build') {
            steps {
                sh '''
                    set -e
                    for svc in backend frontend; do
                        docker build --pull \
                            --label org.opencontainers.image.revision=${GIT_COMMIT} \
                            --label org.opencontainers.image.version=${IMAGE_TAG} \
                            -t order-inventory-${svc}:${IMAGE_TAG} ${APP_DIR}/${svc}
                    done
                    docker images | grep "order-inventory-.*${IMAGE_TAG}"
                '''
            }
        }

        // =========================================================
        // 9. IMAGE SECURITY SCAN (gate: fixable HIGH/CRITICAL)
        // =========================================================
        stage('Image Scan') {
            steps {
                sh '''
                    set -e
                    for svc in backend frontend; do
                        trivy image --scanners vuln --format table --output "${REPORTS}/trivy-image-${svc}.txt" order-inventory-${svc}:${IMAGE_TAG}
                        trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --quiet order-inventory-${svc}:${IMAGE_TAG}
                    done
                '''
            }
        }

        // ============== AWS DEPLOYMENT (params.DEPLOY) ==============

        stage('AWS Identity Check') {
            when { expression { params.DEPLOY } }
            steps {
                script {
                    env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.ECR_REGISTRY = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                }
                sh '''
                    set -e
                    aws sts get-caller-identity --query Arn --output text
                    STATUS=$(aws eks describe-cluster --name ${EKS_CLUSTER} --region ${AWS_REGION} --query cluster.status --output text)
                    echo "EKS cluster status: $STATUS"
                    test "$STATUS" = "ACTIVE"
                '''
            }
        }

        // Only images that passed the tests and security gates above reach ECR
        stage('Push Images to ECR') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -e
                    aws ecr get-login-password --region ${AWS_REGION} \
                        | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    for svc in backend frontend; do
                        docker tag order-inventory-${svc}:${IMAGE_TAG} ${ECR_REGISTRY}/order-inventory-${svc}:${IMAGE_TAG}
                        docker push ${ECR_REGISTRY}/order-inventory-${svc}:${IMAGE_TAG}
                    done
                '''
            }
        }

        stage('Configure Kubernetes') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -e
                    aws eks update-kubeconfig --region ${AWS_REGION} --name ${EKS_CLUSTER}
                    # Jenkins is limited to the application namespace (no cluster-scoped calls)
                    kubectl auth can-i patch deployments -n ${K8S_NAMESPACE}
                    kubectl get deployments -n ${K8S_NAMESPACE}
                '''
            }
        }

        // Helm upgrade, wait for every pod to be Ready, roll back automatically if not
        stage('Deploy to EKS') {
            when { expression { params.DEPLOY } }
            steps {
                script { env.DEPLOY_STARTED = 'true' }
                sh 'ROLLOUT_TIMEOUT=5m ./scripts/deploy-k8s.sh ${ECR_REGISTRY} ${IMAGE_TAG}'
            }
        }

        stage('Kubernetes Verification') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -e
                    kubectl get pods,svc,ingress -n ${K8S_NAMESPACE} -o wide
                    for d in backend frontend; do
                        IMAGE=$(kubectl get deployment $d -n ${K8S_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}')
                        echo "$d -> $IMAGE"
                        case "$IMAGE" in *":${IMAGE_TAG}") ;; *) echo "Unexpected image for $d"; exit 1 ;; esac
                    done
                '''
            }
        }

        // In-cluster readiness (database reachable) + checks through the public ALB
        stage('Application Health Check') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -e
                    kubectl run health-check-${BUILD_NUMBER} --rm -i --restart=Never \
                        --image=curlimages/curl:8.10.1 -n ${K8S_NAMESPACE} -- \
                        curl -fsS --max-time 10 http://backend:8080/api/health/ready

                    ALB_HOST=""
                    for i in $(seq 1 30); do
                        ALB_HOST=$(kubectl get ingress order-inventory-ingress -n ${K8S_NAMESPACE} \
                            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
                        [ -n "$ALB_HOST" ] && break
                        sleep 10
                    done
                    test -n "$ALB_HOST" || { echo "Ingress has no ALB hostname"; exit 1; }

                    # A new ALB's DNS name can take a few minutes to resolve
                    for i in $(seq 1 30); do
                        curl -fsS --max-time 5 "http://$ALB_HOST/api/health" && break
                        sleep 10
                    done

                    if [ "${FULL_SMOKE_TEST}" = "true" ]; then
                        ./scripts/smoke-test.sh "http://$ALB_HOST"
                    else
                        SMOKE_READ_ONLY=1 ./scripts/smoke-test.sh "http://$ALB_HOST"
                    fi
                    echo "$ALB_HOST" > "${REPORTS}/alb-host.txt"
                '''
            }
        }

        stage('Deployment Summary') {
            steps {
                sh '''
                    echo "=================================================="
                    echo "Build:     ${BUILD_NUMBER}   Commit: ${GIT_COMMIT}"
                    echo "Images:    order-inventory-{backend,frontend}:${IMAGE_TAG}"
                    if [ "${DEPLOY}" = "true" ]; then
                        echo "Deployed:  ${EKS_CLUSTER}/${K8S_NAMESPACE} -> http://$(cat "${REPORTS}/alb-host.txt")"
                        echo "Rollback:  helm -n ${K8S_NAMESPACE} rollback ${HELM_RELEASE}"
                    else
                        echo "Deploy:    skipped (DEPLOY=false)"
                    fi
                    echo "=================================================="
                '''
            }
        }
    }

    post {
        failure {
            script {
                // deploy-k8s.sh already rolls back failed rollouts; this covers a release that became
                // Ready but failed the post-deploy health check.
                if (env.DEPLOY_STARTED == 'true') {
                    sh '''
                        if [ -f .deploy/previous-revision ]; then
                            . .deploy/previous-revision
                            if [ -n "${PREV_REVISION}" ]; then
                                echo "Rolling back ${HELM_RELEASE} to revision ${PREV_REVISION}"
                                helm -n ${K8S_NAMESPACE} rollback ${HELM_RELEASE} ${PREV_REVISION} --wait --timeout 5m || true
                            fi
                        fi
                        kubectl get pods -n ${K8S_NAMESPACE} -o wide || true
                    '''
                }
            }
            echo 'PIPELINE FAILED: see the failed stage above; reports are archived with this build.'
        }

        always {
            archiveArtifacts(artifacts: 'reports/**', allowEmptyArchive: true)
            script {
                if (params.DEPLOY && env.CI_REPORTS_BUCKET) {
                    sh 'aws s3 cp --recursive --only-show-errors "${REPORTS}" "s3://${CI_REPORTS_BUCKET}/${JOB_NAME}/${BUILD_NUMBER}/" || echo "Report upload failed (non-fatal)"'
                }
            }
            // Local cleanup only (never affects the cluster or ECR)
            sh '''
                docker rmi order-inventory-backend:${IMAGE_TAG} order-inventory-frontend:${IMAGE_TAG} >/dev/null 2>&1 || true
                [ -n "${ECR_REGISTRY:-}" ] && docker rmi ${ECR_REGISTRY}/order-inventory-backend:${IMAGE_TAG} ${ECR_REGISTRY}/order-inventory-frontend:${IMAGE_TAG} >/dev/null 2>&1 || true
                docker image prune -f >/dev/null 2>&1 || true
            '''
        }
    }
}
