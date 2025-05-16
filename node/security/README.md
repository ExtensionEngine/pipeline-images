# Node Security [![Docker Pulls](https://img.shields.io/docker/pulls/studiondev/node-security)](https://hub.docker.com/r/studiondev/node-security)

Node.js Docker image based on the [`studiondev/node-secrets`](https://hub.docker.com/r/studiondev/node-secrets) with the addition of security tools:

- [Gitleaks](https://github.com/gitleaks/gitleaks)
- [Trivy](https://github.com/aquasecurity/trivy)
- [Semgrep](https://github.com/semgrep/semgrep)

Published on Docker Hub under the name [`studiondev/node-security`](https://hub.docker.com/r/studiondev/node-security/tags).

## Usage

Example usage in CircleCI as a Docker executor:

```
  jobs:
    security-job:
      docker:
        - image: studiondev/node-security
    steps:
      - checkout
      - run: |
          node -v
          infisical -v
          gitleaks -v
          trivy -v
          semgrep -v
```
