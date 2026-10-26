# PetClinic on the shared AKS lab

This fork owns PetClinic source and its app-only deployment workflow. It never creates or destroys AKS. Use the separate [`nr-azure-demo-opentelemetry`](https://github.com/nr-tanderson/nr-azure-demo-opentelemetry) repository for reviewed cluster build/destroy.

The manual **PetClinic on shared AKS** workflow offers:

- `deploy`: run Maven tests, build the Java services from this repo commit, push commit-tagged images to the persistent lab ACR, convert the AKS Compose overlay with Kompose, and deploy into the `petclinic` namespace.
- `uninstall`: remove only the `petclinic` namespace; it does not touch the cluster, ReliBank, Astronomy Shop, Terraform state, or registry.

All generated Kubernetes services are internal except `api-gateway`, which receives a tagged Azure LoadBalancer public IP. The workflow prints the PetClinic URL in its GitHub Actions summary. Anyone who discovers that IP can access this demo; uninstall it when not in use. GenAI, Prometheus, and Grafana are excluded from this lightweight deployment. No OpenAI or New Relic key is required or configured.

## Shared setup

Build the cluster first using the infra repo's **Build AKS infrastructure** workflow. Configure a GitHub Actions environment named `lab-application` in this repo, with required reviewers and a federated Azure OIDC credential for this repo/environment. Set these Actions secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Set these Actions variables to exactly the same shared remote-state values used by the infra repo:

- `TFSTATE_STORAGE_ACCOUNT`
- `TFSTATE_CONTAINER`
- `TFSTATE_KEY`

The Azure identity needs permission to read/write the state/handoff blob, fetch AKS credentials with Azure RBAC, push images to the persistent lab ACR, and operate the cluster. Terraform grants the infra-configured identity `AcrPush` on the registry and the AKS kubelet identity `AcrPull`.

The app workflow checks the active cluster generation and acquires the same blob lease as infra and ReliBank. It fails closed if infra is paused/destroyed or another app/infra operation owns the lease. Only deploy this app while the cluster is active.

The Maven build tags images with the exact Git commit SHA. The workflow skips an image rebuild if that commit already exists in ACR. The fork's Compose overlay keeps services private; only the API gateway is exposed. Runtime chart/config changes should be reviewed in this repo before running the manual workflow.

## Code-change loop

Edit Java code in this PetClinic repo, run its Maven tests locally, push a branch, open a PR, and merge through your normal review rules. Run the manual workflow from the merged commit to build and deploy that exact SHA. The app workflow is manual; pushes do not deploy automatically.

## Troubleshooting

- If the Maven workflow fails while building Docker images, check that the GitHub runner can access ACR and that Maven's `buildDocker` profile supports the selected runner Docker/buildx version.
- If the app is unhealthy, inspect pods and logs in namespace `petclinic`; do not destroy the shared cluster to reset only PetClinic.
- The upstream app uses Config Server and Eureka and may need time to become ready after initial startup. The workflow waits on the service deployments and verifies the public gateway.