# iac-toolchain-hello-world

A hands-on learning project for getting familiar with a modern GitOps toolchain on Azure Kubernetes Service (AKS). The app itself is deliberately trivial — the toolchain is the point.

## What this project covers

| Tool | Layer | Role in this project |
|---|---|---|
| **Pulumi** (TypeScript) | Cloud infrastructure | Provisions an AKS cluster, Azure Container Registry, and the ACR pull role assignment |
| **kpt** | Configuration packaging | Authors and renders Kubernetes manifests as structured data, injecting image tags without raw `sed` or Helm templating |
| **FluxCD** | Continuous delivery | Watches the Git repo and continuously reconciles the live cluster state to match what's committed |
| **Go** | Backend | Minimal HTTP API returning a JSON greeting, containerized to a `scratch`-based image |
| **Dart / Flutter** | Frontend | Flutter web app that calls the Go backend, containerized behind nginx |
| **AKS** | Runtime | The Kubernetes cluster everything runs on |

The three infrastructure tools look like they overlap — they all touch Kubernetes YAML at some point — but they divide the work cleanly: Pulumi never looks at app manifests, kpt never touches a live cluster, and FluxCD never provisions infrastructure.

## Based on

This project follows the guide **"From Zero to GitOps: Go + Flutter on AKS with Pulumi, kpt, and FluxCD"**, included in this repository as [`hello-world-toolchain-guide.md`](./hello-world-toolchain-guide.md). The guide walks through each layer in order, explains *why* every choice was made, and is structured so you can stop after any numbered section with a working, inspectable artifact.
