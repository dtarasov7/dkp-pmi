#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только ресурсы испытания 41."
kubectl delete namespace pmi-41 --ignore-not-found --wait=true --timeout=180s
