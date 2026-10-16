#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "multitenancy-manager" -o jsonpath='{.status.phase}'); then
  echo "Модуль multitenancy-manager: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля multitenancy-manager. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль multitenancy-manager не готов. Выполните kubectl get module multitenancy-manager -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Проверяем необходимые поля API deckhouse.io/v1alpha1."
for FIELD in projecttemplate.spec.parametersSchema.openAPIV3Schema projecttemplate.spec.resourcesTemplate projecttemplate.status.ready; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=deckhouse.io/v1alpha1); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API deckhouse.io/v1alpha1 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Проверяем необходимые поля API deckhouse.io/v1alpha2."
for FIELD in project.spec.projectTemplateName project.spec.parameters project.status.state; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=deckhouse.io/v1alpha2); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API deckhouse.io/v1alpha2 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Создаём собственный шаблон изолированного проекта."
kubectl create -f - <<'YAML'
apiVersion: deckhouse.io/v1alpha1
kind: ProjectTemplate
metadata:
  name: pmi-51
spec:
  description: "Шаблон для приёмочного испытания 51"
  parametersSchema:
    openAPIV3Schema:
      type: object
      properties:
        marker:
          type: string
      required: [marker]
  resourcesTemplate: |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: template-marker
    data:
      marker: {{ .parameters.marker | quote }}
    ---
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: project-quota
    spec:
      hard:
        pods: "10"
    ---
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: isolation
    spec:
      podSelector: {}
      policyTypes: [Ingress, Egress]
      ingress:
      - from:
        - podSelector: {}
      egress:
      - to:
        - podSelector: {}
YAML
kubectl wait --for=jsonpath='{.status.ready}'=true projecttemplate/pmi-51 --timeout=120s
kubectl create -f - <<'YAML'
apiVersion: deckhouse.io/v1alpha2
kind: Project
metadata:
  name: pmi-51
spec:
  description: "Приёмочное испытание 51"
  projectTemplateName: pmi-51
  parameters:
    marker: pmi-51-created-from-template
YAML
echo "Проект передан контроллеру."
