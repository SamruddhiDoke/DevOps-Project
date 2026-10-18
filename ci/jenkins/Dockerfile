# Reproducible Jenkins controller with every tool the Jenkinsfile needs, at pinned versions.
# Used for local CI runs (docker compose -f ci/docker-compose.ci.yml up) and as the reference
# tool list for the Ansible-provisioned Jenkins EC2 host (ansible/group_vars/all.yml).
FROM jenkins/jenkins:2.580.1-lts-jdk21

ARG MAVEN_VERSION=3.9.12
ARG NODE_VERSION=24.22.0
ARG TRIVY_VERSION=0.76.0
ARG HELM_VERSION=4.3.1
ARG KUBECTL_VERSION=1.36.5
ARG TERRAFORM_VERSION=1.15.8
ARG SONAR_SCANNER_VERSION=8.1.0.6389

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils git docker-cli jq \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz | tar -xz -C /opt; \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn; \
    curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz | tar -xJ -C /opt; \
    for b in node npm npx; do ln -s /opt/node-v${NODE_VERSION}-linux-x64/bin/$b /usr/local/bin/$b; done; \
    curl -fsSL https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz | tar -xz -C /usr/local/bin trivy; \
    curl -fsSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz | tar -xz -C /tmp; mv /tmp/linux-amd64/helm /usr/local/bin/helm; \
    curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl; chmod +x /usr/local/bin/kubectl; \
    curl -fsSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip; unzip -q /tmp/tf.zip -d /usr/local/bin; \
    curl -fsSLo /tmp/ss.zip https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip; unzip -q /tmp/ss.zip -d /opt; \
    ln -s /opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    curl -fsSLo /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip; unzip -q /tmp/awscli.zip -d /tmp; /tmp/aws/install; \
    rm -rf /tmp/*

# Jenkins plugins (versions resolved by the LTS update center at build time)
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as Code: job definition, credentials (from environment), no setup wizard
COPY casc.yaml /usr/share/jenkins/ref/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/ref/casc.yaml \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

USER jenkins
