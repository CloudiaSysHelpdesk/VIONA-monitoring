# /opt/jenkins/Dockerfile
FROM jenkins/jenkins:lts-jdk17

USER root
RUN apt-get update && apt-get install -y ca-certificates curl gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && . /etc/os-release \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y docker-ce-cli git make jq \
 && rm -rf /var/lib/apt/lists/*

USER jenkins

