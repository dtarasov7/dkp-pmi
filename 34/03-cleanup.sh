#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 34."
kubectl delete namespace pmi-34 --ignore-not-found --wait=true --timeout=180s
