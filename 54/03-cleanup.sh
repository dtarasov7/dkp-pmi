#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только три тестовых namespace."
kubectl delete namespace pmi-54-privileged pmi-54-baseline pmi-54-restricted --ignore-not-found --wait=true --timeout=180s
