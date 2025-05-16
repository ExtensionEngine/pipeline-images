# Node Secrets [![Docker Pulls](https://img.shields.io/docker/pulls/studiondev/node-secrets)](https://hub.docker.com/r/studiondev/node-secrets)

Node.js Docker image based on the [`cimg/node`](https://hub.docker.com/r/cimg/node) with the addition of [Infisical secret manager](https://github.com/Infisical/infisical).

Published on Docker hub under the name [`studiondev/node-secrets`](https://hub.docker.com/r/studiondev/node-secrets/tags).

## Usage

Example usage in CircleCI as a Docker executor:

```
  jobs:
    secret-job:
      docker:
        - image: studiondev/node-secrets
    steps:
      - checkout
      - run: |
          node -v
          infisical -v
```
