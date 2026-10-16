#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только двух тестовых арендаторов."
kubectl delete namespace pmi-64-a pmi-64-b --ignore-not-found --wait=true --timeout=180s
