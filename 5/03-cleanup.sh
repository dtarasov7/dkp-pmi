#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 5."
kubectl delete namespace pmi-5 --ignore-not-found --wait=true --timeout=180s
