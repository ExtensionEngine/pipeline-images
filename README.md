# CI Docker Images [![Software License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/ExtensionEngine/pipeline-images/master/LICENSE)

A collection of Docker images for use within Studion CircleCI pipelines

- [Node Secrets](/node/secrets/README.md)
- [Node Security](/node/security/README.md)

## Overview

The core of each image definition lies in the `Docker.template` file,
which serves as a blueprint for creating the actual Dockerfile.

Image versions are directly tied to the version of their target runtime environment,
e.g., `Node.js`. For each supported major version of the target runtime environment,
there is a corresponding file, e.g., `20`. These files, which are refer to as **env files**,
contain variables used to customize the Dockerfile generated from the `Docker.template`.

Typically, an **env file** specifies the exact version of the target runtime environment,
the versions of any included tools, and a list of tags to be applied to the built Docker image.

## Tagging

The images in this repository adhere to the following tagging scheme:

```
  <image-name>:<runtime-version>
```

Where:

- `<image-name>` can be one of the following:
  - `studiondev/node-secrets`
  - `studiondev/node-security`
- `<runtime-version>` indicates the version of the target runtime environment to use.
  It is one of the following:
  - **Full Semantic Versioning:** For example, `20.19.2`. This tag points to a specific
    patch version of the target runtime environment.
  - **Major Version:** For example, `20`. This tag points to the latest stable release
    within that major version of the target runtime environment.
  - **Version Alias (`lts`):** This tag, `lts`, is dynamically determined during the build process.
    It refers to the current LTS version of the target runtime environment.

## Build

The process of building and pushing these Docker images is fully automated
through the CI/CD pipeline.

**How it works:**

- Whenever code is pushed to the trunk, the pipeline examines the latest commit
  for modifications to any of the **env files**.
- If changes are detected, a dedicated workflow is automatically triggered.
  This workflow builds the Docker image(s) and afterwards pushes them to Docker Hub.

**Updating an Image:**

To update an image, primarily area of focus is corresponding **env file**:

1.  **Modify the Env File:** Update the versions of the target runtime environment,
    any tools used within the image, and the desired image tags in the relevant **env file**.

    **NOTE** Avoid introducing breaking changes. As a general guideline, follow semantic
    versioning scheme and take the target runtime environment as a reference. For example,
    if bumping a patch version of the target runtime environment, bump only the patch versions
    of the utilized tools as well.

2.  **Commit Changes:** Commit modifications to a feature branch. Adhere to
    the following commit message convention:

    ``feat: `<image-name>` <runtime-versions>``

    For example: ``feat: `node-secrets` 18.20.8, 20.19.2, 22.15.2``

3.  **Create a Pull Request:** Open a pull request with your changes.
4.  **Squash and Merge the Pull Request:** Once your pull request is reviewed and approved,
    squash and merged it. The CI/CD pipeline will automatically detect the changes in the trunk.
    This will initiate the workflow resulting in the updated image being pushed to Docker Hub.

## Limitations

Current approach has a few limitations to be aware of:

- **Manual update process:** Updating image versions is a manual process, which carries
  the risk of specifying non-existent versions for the target runtime environment or other tools.
  These errors will only be caught when the build process fails after the changes are merged into the trunk.
- **Single Dockerfile template:** Currently only support one `Docker.template` file per image.
  This can make it challenging to manage and introduce significant changes for new major versions of
  the target runtime environment without potentially breaking compatibility with older versions.
- **Inter-image dependency:** The `node-security` image has a dependency on the `node-secrets` image.
  This means that the `node-secrets` image must be successfully pushed before any changes can be
  made to the `node-security` image.
- **Last commit inspection:** The CI/CD pipeline only inspects the very last commit pushed to the trunk
  for the image-related changes. If multiple commits are pushed at once, changes in earlier
  commits will be missed, and the image update process will not be triggered.
