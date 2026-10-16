#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 56."
kubectl delete namespace pmi-56 --ignore-not-found --wait=true --timeout=180s
