#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только созданный проект, его namespace и собственный шаблон."
kubectl delete project pmi-51 --ignore-not-found --wait=true --timeout=180s
kubectl delete namespace pmi-51 --ignore-not-found --wait=true --timeout=180s
kubectl delete projecttemplate pmi-51 --ignore-not-found
