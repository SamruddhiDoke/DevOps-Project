pipeline {

    agent any

    environment {

        // =========================================================
        // AWS
        // =========================================================
        AWS_REGION = 'ap-south-1'
        AWS_ACCOUNT_ID = '038215676861'

        ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

        // =========================================================
        // ECR REPOSITORIES
        // =========================================================
        BACKEND_IMAGE = "${ECR_REGISTRY}/order-inventory-backend"
        FRONTEND_IMAGE = "${ECR_REGISTRY}/order-inventory-frontend"

        // =========================================================
        // EKS
        // =========================================================
        EKS_CLUSTER = 'order-inventory-eks'
        K8S_NAMESPACE = 'order-inventory'

        // Jenkins build number becomes the image version
        IMAGE_TAG = "${BUILD_NUMBER}"
    }

    options {

        // Prevent two deployments running at the same time
        disableConcurrentBuilds()

        // Keep only the latest 10 builds
        buildDiscarder(
            logRotator(numToKeepStr: '10')
        )

        // Maximum pipeline execution time
        timeout(
            time: 30,
            unit: 'MINUTES'
        )

        // Add timestamps to Jenkins console output
        timestamps()
    }

    stages {

        // =========================================================
        // 1. CHECKOUT
        // =========================================================
        stage('Checkout') {

            steps {

                echo 'Checking out source code from GitHub...'

                checkout scm

                sh '''
                    echo "========================================"
                    echo "Git Commit"
                    echo "========================================"

                    git rev-parse --short HEAD

                    echo "========================================"
                    echo "Git Branch"
                    echo "========================================"

                    git branch --show-current

                    echo "========================================"
                    echo "Project Structure"
                    echo "========================================"

                    ls -la
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

                    echo "========================================"
                    echo "JAVA"
                    echo "========================================"

                    java -version

                    echo "========================================"
                    echo "MAVEN"
                    echo "========================================"

                    mvn -version

                    echo "========================================"
                    echo "NODE"
                    echo "========================================"

                    node --version

                    echo "========================================"
                    echo "NPM"
                    echo "========================================"

                    npm --version

                    echo "========================================"
                    echo "DOCKER"
                    echo "========================================"

                    docker --version

                    echo "========================================"
                    echo "AWS CLI"
                    echo "========================================"

                    aws --version

                    echo "========================================"
                    echo "KUBECTL"
                    echo "========================================"

                    kubectl version --client

                    echo "========================================"
                    echo "HELM"
                    echo "========================================"

                    helm version
                '''
            }
        }


        // =========================================================
        // 3. BACKEND TESTS
        // =========================================================
        stage('Backend Tests') {

            steps {

                dir('backend') {

                    sh '''
                        set -e

                        echo "========================================"
                        echo "Running Spring Boot tests"
                        echo "========================================"

                        mvn clean test
                    '''
                }
            }

            post {

                always {

                    junit(
                        testResults: 'backend/target/surefire-reports/*.xml',
                        allowEmptyResults: true
                    )
                }
            }
        }


        // =========================================================
        // 4. FRONTEND BUILD
        // =========================================================
        stage('Frontend Build') {

            steps {

                dir('frontend') {

                    sh '''
                        set -e

                        echo "========================================"
                        echo "Installing frontend dependencies"
                        echo "========================================"

                        npm ci

                        echo "========================================"
                        echo "Building React application"
                        echo "========================================"

                        npm run build

                        echo "========================================"
                        echo "Frontend build completed"
                        echo "========================================"

                        ls -lah dist
                    '''
                }
            }
        }


        // =========================================================
        // 5. DOCKER BUILD
        // =========================================================
        stage('Docker Build') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Building Backend Docker Image"
                    echo "========================================"

                    docker build \
                        -t ${BACKEND_IMAGE}:${IMAGE_TAG} \
                        -t ${BACKEND_IMAGE}:latest \
                        ./backend

                    echo "========================================"
                    echo "Building Frontend Docker Image"
                    echo "========================================"

                    docker build \
                        -t ${FRONTEND_IMAGE}:${IMAGE_TAG} \
                        -t ${FRONTEND_IMAGE}:latest \
                        ./frontend

                    echo "========================================"
                    echo "Docker Images"
                    echo "========================================"

                    docker images | grep order-inventory
                '''
            }
        }


        // =========================================================
        // 6. AWS IDENTITY CHECK
        // =========================================================
        stage('AWS Identity Check') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "AWS Identity"
                    echo "========================================"

                    aws sts get-caller-identity

                    echo "========================================"
                    echo "Checking EKS Cluster"
                    echo "========================================"

                    aws eks describe-cluster \
                        --name ${EKS_CLUSTER} \
                        --region ${AWS_REGION} \
                        --query "cluster.status" \
                        --output text
                '''
            }
        }


        // =========================================================
        // 7. ECR LOGIN
        // =========================================================
        stage('ECR Login') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Logging into Amazon ECR"
                    echo "========================================"

                    aws ecr get-login-password \
                        --region ${AWS_REGION} \
                    | docker login \
                        --username AWS \
                        --password-stdin ${ECR_REGISTRY}

                    echo "ECR login successful"
                '''
            }
        }


        // =========================================================
        // 8. PUSH IMAGES
        // =========================================================
        stage('Push Images to ECR') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Pushing Backend Image"
                    echo "========================================"

                    docker push ${BACKEND_IMAGE}:${IMAGE_TAG}

                    echo "========================================"
                    echo "Pushing Frontend Image"
                    echo "========================================"

                    docker push ${FRONTEND_IMAGE}:${IMAGE_TAG}

                    echo "========================================"
                    echo "Pushing Latest Tags"
                    echo "========================================"

                    docker push ${BACKEND_IMAGE}:latest
                    docker push ${FRONTEND_IMAGE}:latest

                    echo "Images successfully pushed to ECR"
                '''
            }
        }


        // =========================================================
        // 9. CONFIGURE KUBECTL
        // =========================================================
        stage('Configure Kubernetes') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Configuring kubectl for EKS"
                    echo "========================================"

                    aws eks update-kubeconfig \
                        --region ${AWS_REGION} \
                        --name ${EKS_CLUSTER}

                    echo "========================================"
                    echo "Current Kubernetes Context"
                    echo "========================================"

                    kubectl config current-context

                    echo "========================================"
                    echo "Cluster Nodes"
                    echo "========================================"

                    kubectl get nodes
                '''
            }
        }


        // =========================================================
        // 10. UPDATE BACKEND IMAGE
        // =========================================================
        stage('Update Backend') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Updating Backend Deployment"
                    echo "========================================"

                    kubectl set image \
                        deployment/backend \
                        backend=${BACKEND_IMAGE}:${IMAGE_TAG} \
                        -n ${K8S_NAMESPACE}

                    echo "Backend image updated to:"
                    echo "${BACKEND_IMAGE}:${IMAGE_TAG}"
                '''
            }
        }


        // =========================================================
        // 11. UPDATE FRONTEND IMAGE
        // =========================================================
        stage('Update Frontend') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Updating Frontend Deployment"
                    echo "========================================"

                    kubectl set image \
                        deployment/frontend \
                        frontend=${FRONTEND_IMAGE}:${IMAGE_TAG} \
                        -n ${K8S_NAMESPACE}

                    echo "Frontend image updated to:"
                    echo "${FRONTEND_IMAGE}:${IMAGE_TAG}"
                '''
            }
        }


        // =========================================================
        // 12. KUBERNETES ROLLOUT
        // =========================================================
        stage('Kubernetes Rollout') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Backend Rollout"
                    echo "========================================"

                    kubectl rollout status \
                        deployment/backend \
                        -n ${K8S_NAMESPACE} \
                        --timeout=5m

                    echo "Backend rollout successful"

                    echo "========================================"
                    echo "Frontend Rollout"
                    echo "========================================"

                    kubectl rollout status \
                        deployment/frontend \
                        -n ${K8S_NAMESPACE} \
                        --timeout=5m

                    echo "Frontend rollout successful"
                '''
            }
        }


        // =========================================================
        // 13. VERIFY KUBERNETES
        // =========================================================
        stage('Kubernetes Verification') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Pods"
                    echo "========================================"

                    kubectl get pods \
                        -n ${K8S_NAMESPACE} \
                        -o wide

                    echo "========================================"
                    echo "Deployments"
                    echo "========================================"

                    kubectl get deployments \
                        -n ${K8S_NAMESPACE}

                    echo "========================================"
                    echo "Services"
                    echo "========================================"

                    kubectl get services \
                        -n ${K8S_NAMESPACE}
                '''
            }
        }


        // =========================================================
        // 14. APPLICATION HEALTH CHECK
        // =========================================================
        stage('Application Health Check') {

            steps {

                sh '''
                    set -e

                    echo "========================================"
                    echo "Testing Backend Health Endpoint"
                    echo "========================================"

                    kubectl run health-check \
                        --rm \
                        --restart=Never \
                        --image=curlimages/curl:8.10.1 \
                        -n ${K8S_NAMESPACE} \
                        -- \
                        curl -f --max-time 10 \
                        http://backend:8080/api/health

                    echo ""
                    echo "========================================"
                    echo "APPLICATION HEALTH CHECK PASSED"
                    echo "========================================"
                '''
            }
        }


        // =========================================================
        // 15. FINAL STATUS
        // =========================================================
        stage('Deployment Summary') {

            steps {

                sh '''
                    echo ""
                    echo "=================================================="
                    echo "          DEPLOYMENT COMPLETED"
                    echo "=================================================="

                    echo "Build Number:"
                    echo "${BUILD_NUMBER}"

                    echo ""
                    echo "Backend Image:"
                    echo "${BACKEND_IMAGE}:${IMAGE_TAG}"

                    echo ""
                    echo "Frontend Image:"
                    echo "${FRONTEND_IMAGE}:${IMAGE_TAG}"

                    echo ""
                    echo "EKS Cluster:"
                    echo "${EKS_CLUSTER}"

                    echo ""
                    echo "Namespace:"
                    echo "${K8S_NAMESPACE}"

                    echo ""
                    echo "=================================================="
                '''
            }
        }
    }


    // =============================================================
    // POST ACTIONS
    // =============================================================

    post {

        success {

            echo '''
            ==================================================
                    DEPLOYMENT SUCCESSFUL
            ==================================================

            Jenkins successfully:

            ✓ Checked out GitHub code
            ✓ Ran backend tests
            ✓ Built frontend
            ✓ Built Docker images
            ✓ Logged into Amazon ECR
            ✓ Pushed images to ECR
            ✓ Updated Kubernetes deployments
            ✓ Completed Kubernetes rollout
            ✓ Verified application health

            ==================================================
            '''
        }


        failure {

            echo '''
            ==================================================
                       PIPELINE FAILED
            ==================================================

            One or more pipeline stages failed.

            Check the Jenkins console output above
            to identify the failed stage.

            ==================================================
            '''
        }


        always {

            echo 'Cleaning unused Docker resources...'

            sh '''
                docker image prune -f || true
            '''
        }
    }
}