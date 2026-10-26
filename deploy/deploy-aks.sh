#!/usr/bin/env bash
set -euo pipefail

connection=$(mktemp)
manifest=$(mktemp)
trap 'rm -f "$connection" "$manifest"' EXIT

az storage blob download \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --container-name "$TFSTATE_CONTAINER" \
  --name "${TFSTATE_KEY}.connection.json" \
  --file "$connection" \
  --auth-mode login \
  --overwrite \
  --output none

test "$(jq -r .state "$connection")" = active
resource_group=$(jq -r .resource_group "$connection")
cluster=$(jq -r .cluster "$connection")
registry=$(jq -r .registry "$connection")
registry_url=$(jq -r .registry_url "$connection")
generation=$(jq -r .generation "$connection")
actual_generation=$(az aks show --resource-group "$resource_group" --name "$cluster" --query tags.LAB_GENERATION --output tsv)
test "$generation" = "$actual_generation"

az aks get-credentials --resource-group "$resource_group" --name "$cluster" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

if [[ "$PETCLINIC_OPERATION" == uninstall ]]; then
  kubectl delete namespace petclinic --ignore-not-found --wait=true --timeout=5m
  printf 'PetClinic removed from lab generation %s.\n' "$generation" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

[[ "$PETCLINIC_OPERATION" == deploy ]]
az acr login --name "$registry"
prefix="$registry_url/petclinic"
first_image="petclinic/spring-petclinic-api-gateway:$GITHUB_SHA"
if ! az acr repository show --name "$registry" --image "$first_image" --output none 2>/dev/null; then
  ./mvnw --batch-mode test
  ./mvnw --batch-mode -DskipTests -PbuildDocker clean install \
    -Ddocker.image.prefix="$prefix" \
    -Ddocker.image.tag="$GITHUB_SHA" \
    -Dcontainer.build.extraarg=--push \
    -Dcontainer.platform=linux/amd64
fi

OPENAI_API_KEY='' AZURE_OPENAI_KEY='' AZURE_OPENAI_ENDPOINT='' \
PETCLINIC_IMAGE_PREFIX="$prefix" PETCLINIC_IMAGE_TAG="$GITHUB_SHA" \
  kompose convert \
    -f docker-compose.yml \
    -f deploy/docker-compose-aks.yml \
    --namespace petclinic \
    --out "$manifest"

kubectl apply -f "$manifest"
kubectl patch service api-gateway --namespace petclinic --type merge \
  --patch '{"metadata":{"annotations":{"service.beta.kubernetes.io/azure-additional-resource-tags":"OWNER=TANDERSON,PROJECT=nr-azure-demo-opentelemetry"}},"spec":{"type":"LoadBalancer"}}'

for deployment in config-server discovery-server customers-service visits-service vets-service api-gateway admin-server tracing-server; do
  kubectl rollout status "deployment/$deployment" --namespace petclinic --timeout=10m
done

kubectl wait --namespace petclinic --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' service/api-gateway --timeout=300s
public_ip=$(kubectl get service api-gateway --namespace petclinic --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
for attempt in $(seq 1 30); do
  printf 'PetClinic readiness attempt %s/30\n' "$attempt"
  if curl --fail --silent "http://${public_ip}:8080/" >/dev/null; then break; fi
  sleep 5
done
curl --fail --silent --output /dev/null --write-out 'PetClinic HTTP %{http_code}\n' "http://${public_ip}:8080/"
printf 'PetClinic URL: http://%s:8080/\nCommit: %s\nGeneration: %s\n' "$public_ip" "$GITHUB_SHA" "$generation" >> "$GITHUB_STEP_SUMMARY"