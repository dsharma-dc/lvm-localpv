#!/usr/bin/env bash

set -e

SNAP_CLASS="$(realpath deploy/sample/lvmsnapclass.yaml)"

export TEST_DIR="tests"

# allow override
if [ -z "${KUBECONFIG}" ]
then
  export KUBECONFIG="${HOME}/.kube/config"
fi

# foreign systemid for the testing environment.
FOREIGN_LVM_SYSTEMID="openebs-ci-test-system"
FOREIGN_LVM_CONFIG="global{system_id_source=lvmlocal}local{system_id=${FOREIGN_LVM_SYSTEMID}}"
CRDS_TO_DELETE_ON_CLEANUP="lvmnodes.local.openebs.io lvmsnapshots.local.openebs.io lvmvolumes.local.openebs.io volumesnapshotclasses.snapshot.storage.k8s.io volumesnapshotcontents.snapshot.storage.k8s.io volumesnapshots.snapshot.storage.k8s.io"

# Clean up generated resources for successive tests.
cleanup_loopdev() {
  sudo losetup -l | grep '(deleted)' | awk '{print $1}' \
    | while IFS= read -r disk
      do
        sudo losetup -d "${disk}"
      done
}

cleanup_foreign_lvmvg() {
  if [ -f /tmp/openebs_ci_foreign_disk.img ]
  then
    sudo vgremove foreign_lvmvg --config="${FOREIGN_LVM_CONFIG}" -y || true
    sudo rm /tmp/openebs_ci_foreign_disk.img
  fi
  cleanup_loopdev
}

cleanup() {
  set +e

  echo "Cleaning up test resources"

  cleanup_foreign_lvmvg

  kubectl delete pvc -n "$OPENEBS_NAMESPACE" lvmpv-pvc
  kubectl delete -f "${SNAP_CLASS}"

  helm uninstall lvm-localpv -n "$OPENEBS_NAMESPACE" || true
  kubectl delete crds "$CRDS_TO_DELETE_ON_CLEANUP"
  # always return true
  return 0
}
# trap "cleanup 2>/dev/null" EXIT
[ -n "${CLEANUP_ONLY}" ] && cleanup 2>/dev/null && exit 0
[ -n "${RESET}" ] && cleanup 2>/dev/null


# setup a foreign lvm to test
cleanup_foreign_lvmvg
truncate -s 100G /tmp/openebs_ci_foreign_disk.img
foreign_disk="$(sudo losetup -f /tmp/openebs_ci_foreign_disk.img --show)"
sudo pvcreate "${foreign_disk}"
sudo vgcreate foreign_lvmvg "${foreign_disk}" --config="${FOREIGN_LVM_CONFIG}"

# install snapshot and thin volume module for lvm
sudo modprobe dm-snapshot
sudo modprobe dm_thin_pool

# Set the configuration for thin pool autoextend in lvm.conf
sudo sed -i '/^[^#]*thin_pool_autoextend_threshold/ s/= .*/= 50/' /etc/lvm/lvm.conf
sudo sed -i '/^[^#]*thin_pool_autoextend_percent/ s/= .*/= 20/' /etc/lvm/lvm.conf

# Prepare env for running BDD tests
# Minikube is already running
helm install lvm-localpv ./deploy/helm/charts -n "$OPENEBS_NAMESPACE" --create-namespace --set lvmPlugin.pullPolicy=Never --set analytics.enabled=false
kubectl apply -f "${SNAP_CLASS}"

dumpAgentLogs() {
  NR=$1
  AgentPOD=$(kubectl get pods -l app=openebs-lvm-node -o jsonpath='{.items[0].metadata.name}' -n "$OPENEBS_NAMESPACE")
  kubectl describe po "$AgentPOD" -n "$OPENEBS_NAMESPACE"
  printf "\n\n"
  kubectl logs --tail="${NR}" "$AgentPOD" -n "$OPENEBS_NAMESPACE" -c openebs-lvm-plugin
  printf "\n\n"
}

dumpControllerLogs() {
  NR=$1
  ControllerPOD=$(kubectl get pods -l app=openebs-lvm-controller -o jsonpath='{.items[0].metadata.name}' -n "$OPENEBS_NAMESPACE")
  kubectl describe po "$ControllerPOD" -n "$OPENEBS_NAMESPACE"
  printf "\n\n"
  kubectl logs --tail="${NR}" "$ControllerPOD" -n "$OPENEBS_NAMESPACE" -c openebs-lvm-plugin
  printf "\n\n"
}

isPodReady(){
  [ "$(kubectl get po "$1" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' -n "$OPENEBS_NAMESPACE")" = 'True' ]
}

isDriverReady(){
  for pod in $lvmDriver;do
    isPodReady "$pod" || return 1
  done
}

waitForLVMDriver() {
  period=120
  interval=1

  i=0
  while [ "$i" -le "$period" ]; do
    lvmDriver="$(kubectl get pods -l role=openebs-lvm -o 'jsonpath={.items[*].metadata.name}' -n "$OPENEBS_NAMESPACE")"
    if isDriverReady "$lvmDriver"; then
      return 0
    fi

    i=$(( i + interval ))
    echo "Waiting for lvm-driver to be ready..."
    sleep "$interval"
  done

  echo "Waited for $period seconds, but all pods are not ready yet."
  return 1
}

# wait for lvm-driver to be up
waitForLVMDriver

cd $TEST_DIR

kubectl get po -n "$OPENEBS_NAMESPACE"

set +e

echo "running ginkgo test case"

if ! ginkgo -v -coverprofile=bdd_coverage.txt -covermode=atomic; then

sudo pvscan --cache

sudo lvdisplay

sudo vgdisplay

echo "******************** LVM Controller logs***************************** "
dumpControllerLogs 1000

echo "********************* LVM Agent logs *********************************"
dumpAgentLogs 1000

echo "get all the pods"
kubectl get pods -owide --all-namespaces

echo "get pvc and pv details"
kubectl get pvc,pv -oyaml --all-namespaces

echo "get snapshot details"
kubectl get volumesnapshot.snapshot -oyaml --all-namespaces

echo "get sc details"
kubectl get sc --all-namespaces -oyaml

echo "get lvm volume details"
kubectl get lvmvolumes.local.openebs.io -n "$OPENEBS_NAMESPACE" -oyaml

echo "get lvm snapshot details"
kubectl get lvmsnapshots.local.openebs.io -n "$OPENEBS_NAMESPACE" -oyaml

exit 1
fi

printf "\n\n######### All test cases passed #########\n\n"

# last statement formatted to always return true
[ -z "${CLEANUP}" ] || cleanup 2>/dev/null