#!/bin/bash

## Builds and deploys the code in the repository, and then runs an upload test as a user.
## Notes:
## - only works for openshift. Get one form here: https://demo.redhat.com/catalog
## - make sure the variables below are set correctly
## - The build and deploy step:
##     - if the spi-system namespace does not exist `make deploy_openshift is used, otherwise
##       the image is updated and the services are restarted.
##     - to skip this step specify a parameter (value does not matter) when invoking the script.
## - The user namespace will be deleted and recreated each time the script is run.
##


DEPLOY="deploy_openshift"
USER_PASSWORD="0sw4f0RzxfwyPj2v"
USER_NAMESPACE="user1ns"
ADMIN_PASSWORD="30NNs0upDhhW8Q0R"
USER_NAMESPACE="user1ns"
REPO_DIR="/Users/martinmulholland/go/src/github.com/redhat-appstudio/service-provider-integration-operator"
QUAY="quay.io/mmulholl/service-provider-integration-oauth"
UPLOAD_TOKEN="bathtub_cat_11ARBCTMQ08QNmp7Gb1rsG_2O0aMWfHrht2zUC6bdQvDpUwPxY5BrBILDkR6FdnpelINH2V2I2nhLnT7hp"


check_namespace() {
  NS="$1"
  PODS=$(kubectl get namespace $NS 2>&1)
  if [[ "$PODS" == *"\"$NS\" not found"* ]]; then
    echo "false"
  else
    echo "true"
  fi
}

buildAndDeploy() {
  TAG_NAME=$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)'_'$(date '+%Y_%m_%d__%H_%M_%S')
  TAG_NAME=${TAG_NAME//[\/]/_}
  echo -e '\n\n\tBuild and deploy 1. deploying SPI OAuth to '$(kubectl config current-context)
  cd $REPO_DIR

  SPIS_IMG="$QUAY:"$TAG_NAME
  make docker-build-oauth docker-push-oauth SPIS_IMG=$SPIS_IMG
  echo -e '\n\n\tBuild and deploy 2. using oauth image='$SPIS_IMG
  if [[ "$(check_namespace "spi-system")" == "false" ]]; then
      echo -e "\n\n\tBuild and deploy 3. nmake $DEPLOY using new image"
      make $DEPLOY SPIS_IMG=$SPIS_IMG
      echo -e "\n\n\tBuild and deploy 4.. apply secrets\n"
      kubectl apply -f $REPO_DIR/.tmp/approle_secret.yaml -n spi-system
      kubectl apply -f $REPO_DIR/.tmp/approle_remote_secret.yaml -n remotesecret
  else
      echo -e "\n\n\tBuild and deploy 3. restart oauth service with rebuilt manifests and new image"
      make manifests
      make kustomize
      kubectl set image deployment/spi-oauth-service oauth=$SPIS_IMG -n spi-system
      kubectl -n spi-system rollout restart deployment/spi-controller-manager deployment/spi-oauth-service
  fi
}

uploadSpiToken(){
  if [ "$#" -ne 4 ]; then
      echo -e '\n\nuploadSpiToken->\t\t\tIllegal number of parameters. Expected 4, got '"$#"
      return
  fi
  NS="$1"
  OBJ_NAME="$2"
  AUTHORIZATION_TOKEN="$3"
  SPI_TOKEN="$4"
  echo -e '\n\n\tUpload 1. uploadSpiToken->\tget SPIAccessTokenBinding, name: '"$OBJ_NAME"', namespace: '"$NS"
  kubectl wait  --for jsonpath='{.status.uploadUrl}' spiaccesstokenbinding/$OBJ_NAME -n $NS --timeout=60s 2>&1
  UPLOAD_URL=$(kubectl get spiaccesstokenbinding "$OBJ_NAME" -n "$NS" -o  json | jq -r .status.uploadUrl)
  echo -e '\n\n\tUpload 2. Run curl command using: '$UPLOAD_URL
  if [[ "$UPLOAD_URL" == "" ]]; then
    echo "FAIL: failed to obtain an upload url"
  else
    CURL_RESP=$(curl --ssl-reqd --retry 5 -s \
      -H 'Content-Type: application/json' \
      -H 'Authorization: bearer '"$AUTHORIZATION_TOKEN" \
      -d "{ \"access_token\": \"$SPI_TOKEN\" }" \
      "$UPLOAD_URL")
    if [[ "$CURL_RESP" != *"Application is not available"* ]]; then
        echo -e "\n\n\tUpload 3. Now wait for response from namespace $NS......."
        RESP=$(kubectl wait  --for jsonpath='{.status.phase}'=Injected spiaccesstokenbinding/$OBJ_NAME -o=jsonpath='{.status}' -n $NS  --timeout=60s 2>&1)
        if [[ "$RESP" == *"\"phase\":\"Injected\""* ]]; then
            echo -e '\n\n!!!!!!!\nPASS: uploadSpiToken->\tToken uploaded\n!!!!!!!\n'
        else
            echo "FAIL: Upload failed: $RESP"
            echo "expected status.phase to be Injected: but found $(kubectl get spiaccesstokenbinding $OBJ_NAME -n $NS -o=jsonpath='{.status.phase}')"
        fi
    else
        echo "FAIL: no application available at "$UPLOAD_URL
    fi
 fi
}

echo -e "\n\n1. log into admin\n"
oc login -u admin -p $ADMIN_PASSWORD

if [[ "$#" == 0 ]]; then
    echo -e "\n1a. build and deploy\n"
    buildAndDeploy
fi

if [[ "$(check_namespace "spi-system")" == "false" ]]; then
  echo -e "\n\n\nFailed to install!!"
  exit 1
fi

echo -e "\n2. delete and create namespace $USER_NAMESPACE\n"
kubectl delete namespace $USER_NAMESPACE --ignore-not-found=true
kubectl create namespace $USER_NAMESPACE
oc config set-context --current --namespace=$USER_NAMESPACE

# as user

echo -e "\n3. give $USER permissions for spiaccesstokenbinding from hack/give-default-sa-perms-for-accesstokens.yaml\n"
kubectl apply -f hack/give-default-sa-perms-for-accesstokens.yaml -n $USER_NAMESPACE
kubectl patch rolebinding accesstokens-for-default-sa --patch "subjects: [ {'kind' : 'User', 'name' : "$USER" } ]" -n $USER_NAMESPACE

echo -e "\n4. login as $USER\n"
oc login -u $USER -p $USER_PASSWORD

## samples/spiaccesstokenbinding.yaml modified to specify usern1s namespace
echo -e "\n5.modify namespace in samples/spiaccesstokenbinding.yaml to $USER_NAMESPACE"

while IFS= read -r line
  do
    if [[ "$line" == *"namespace: "* ]]; then
      ORIG_NAMESPACE=$(echo $line | sed -e 's/^[ ]*//' | sed -e 's/\ *$//g')
    fi
  done < ./samples/spiaccesstokenbinding.yaml

NEW_NAMESPACE="namespace: $USER_NAMESPACE"
sed -i "s/$ORIG_NAMESPACE/$NEW_NAMESPACE/g" ./samples/spiaccesstokenbinding.yaml


echo -e "\n6. create sample spiaccestokenbinding from samples/spiaccesstokenbinding.yaml\n"
kubectl apply -f samples/spiaccesstokenbinding.yaml -n $USER_NAMESPACE

token=$(oc whoami -t token)
echo -e "\n7. upload token to test-access-token-binding\n"
uploadSpiToken "user1ns" "test-access-token-binding" "$token" "$UPLOAD_TOKEN"

echo -e "\n8. revert change to namespace in ./samples/spiaccesstokenbinding.yaml"
sed -i "s/$NEW_NAMESPACE/$ORIG_NAMESPACE/g" ./samples/spiaccesstokenbinding.yaml

echo -e "\n9. log back into admin\n"
oc login -u admin -p $ADMIN_PASSWORD
