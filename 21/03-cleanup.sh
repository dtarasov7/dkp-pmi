#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только namespace pmi-21 с тестовым Deployment и Job."
kubectl delete namespace pmi-21 --ignore-not-found --wait=true --timeout=180s
