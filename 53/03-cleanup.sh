#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 53."
kubectl delete namespace pmi-53 --ignore-not-found --wait=true --timeout=180s
