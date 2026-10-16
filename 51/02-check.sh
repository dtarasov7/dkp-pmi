#!/usr/bin/env bash
set -euo pipefail

echo "Ожидаем создания ресурсов контроллером проекта."
kubectl wait --for=jsonpath='{.status.state}'=Deployed project/pmi-51 --timeout=180s
kubectl get project pmi-51 -o yaml
kubectl -n pmi-51 get configmap,resourcequota,networkpolicy
MARKER=$(kubectl -n pmi-51 get configmap template-marker -o jsonpath='{.data.marker}')
echo "Параметр из шаблона: $MARKER"
if [ "$MARKER" != pmi-51-created-from-template ]; then
  echo "ОШИБКА: параметр шаблона не применён."
  exit 1
fi
QUOTA=$(kubectl -n pmi-51 get resourcequota project-quota -o jsonpath='{.spec.hard.pods}')
echo "Квота Pod: $QUOTA"
if [ "$QUOTA" != 10 ]; then
  echo "ОШИБКА: квота не соответствует шаблону."
  exit 1
fi
kubectl -n pmi-51 get networkpolicy isolation -o yaml
echo "УСПЕХ: проект создан по шаблону с маркером, квотой и политикой изоляции."
