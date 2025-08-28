#!/usr/bin/env bash
set -euo pipefail

kubectl get deploy,ds,sts,job,cronjob -A -o json \
  | jq -r '
    .items[]
    | . as $parent
    | (["containers","initContainers"][]
      | select($parent.spec.template.spec[.] != null)
      | . as $ctype
      | $parent.spec.template.spec[$ctype][]
      | select(.image | test("bitnami"))
      | [
          $parent.kind,
          $parent.metadata.name,
          $parent.metadata.namespace,
          $ctype,
          .name,
          .image
        ]
      | @tsv )' \
  | column -t
