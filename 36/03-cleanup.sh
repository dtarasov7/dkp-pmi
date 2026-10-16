#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 36."
kubectl delete clusterrolebinding pmi-36-editor --ignore-not-found
kubectl delete clusterrole pmi-36-editor --ignore-not-found
kubectl delete securitypolicy pmi-36 --ignore-not-found
kubectl delete namespace pmi-36 --ignore-not-found --wait=true --timeout=180s
