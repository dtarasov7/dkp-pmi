#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 37."
kubectl delete clusterrolebinding pmi-37-editor --ignore-not-found
kubectl delete clusterrole pmi-37-editor --ignore-not-found
kubectl delete securitypolicy pmi-37 --ignore-not-found
kubectl delete namespace pmi-37 --ignore-not-found --wait=true --timeout=180s
