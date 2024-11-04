FROM studiondev/node-secrets:22.10.0

# Copy executables directly from images to avoid using insecure curl
COPY --from=zricethezav/gitleaks:v8.21.1 /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=aquasec/trivy:0.56.2 /usr/local/bin/trivy /usr/local/bin/trivy

# Install Semgrep explicitly, since coping from the image won't work due to Python bindings
RUN sudo apt update
RUN sudo apt install -y python3 python3-pip
RUN sudo pip3 install semgrep==1.93.0
