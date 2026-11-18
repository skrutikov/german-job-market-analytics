#!/usr/bin/env bash
# Transactional maintenance window for offline copies of SQLite-backed PVCs.
# Sourced by backup.sh; uses remote(), die() and check_quiesced().
maintenance_restore_auto=""
maintenance_restore_airflow=""
maintenance_restore_grafana=""
maintenance_airflow_changed=false
maintenance_grafana_changed=false

patch_argo_auto() {
  local ns="$1" value="$2"
  printf '{"spec":{"syncPolicy":{"automated":{"enabled":%s}}}}' "$value" |
    remote "sudo -n k3s kubectl -n argocd patch application job-market-$ns --type=merge --patch-file=/dev/stdin" >/dev/null
}

begin_maintenance() {
  local ns="$1" app_mode active_jobs workload attempt stopped
  maintenance_restore_airflow="$(remote "sudo -n k3s kubectl -n $ns get deployment airflow -o jsonpath='{.spec.replicas}'")"
  maintenance_restore_grafana="$(remote "sudo -n k3s kubectl -n $ns get deployment grafana -o jsonpath='{.spec.replicas}'")"
  [[ "$maintenance_restore_airflow" =~ ^[0-9]+$ &&
     "$maintenance_restore_grafana" =~ ^[0-9]+$ ]] ||
    die "Cannot determine original replica counts"

  active_jobs="$(remote "sudo -n k3s kubectl -n $ns get jobs -o json" |
    python3 -c 'import json,sys; print(sum(j.get("status",{}).get("active",0) for j in json.load(sys.stdin).get("items",[])))')"
  [[ "$active_jobs" == 0 ]] ||
    die "$ns has $active_jobs active ETL Jobs; try again after they finish"

  app_mode="$(remote "sudo -n k3s kubectl -n argocd get application job-market-$ns -o json" |
    python3 -c 'import json,sys; a=json.load(sys.stdin).get("spec",{}).get("syncPolicy",{}).get("automated"); print("off" if a is None or a.get("enabled") is False else ("null" if a.get("enabled") is None else "true"))')"
  if [[ "$app_mode" != off ]]; then
    # Store recovery action before the patch in case SSH drops mid-operation.
    maintenance_restore_auto="$app_mode"
    patch_argo_auto "$ns" false
  fi

  # Save and restore exactly the former replica counts, including zero.
  maintenance_airflow_changed=true
  remote "sudo -n k3s kubectl -n $ns scale deployment/airflow --replicas=0" >/dev/null
  maintenance_grafana_changed=true
  remote "sudo -n k3s kubectl -n $ns scale deployment/grafana --replicas=0" >/dev/null

  for workload in airflow grafana; do
    stopped=false
    for ((attempt=1; attempt<=90; attempt++)); do
      local pod_names
      pod_names="$(remote "sudo -n k3s kubectl -n $ns get pods -l app=$workload -o name")" ||
        die "Could not check $workload Pods over SSH"
      if [[ -z "$pod_names" ]]; then
        stopped=true
        break
      fi
      sleep 2
    done
    "$stopped" || die "Timed out waiting for $workload to stop"
  done
  check_quiesced "$ns"
}

end_maintenance() {
  local ns="$1" failed=0
  # Never let a failed command suppress the remaining recovery attempts.
  if "$maintenance_airflow_changed"; then
    remote "sudo -n k3s kubectl -n $ns scale deployment/airflow --replicas=$maintenance_restore_airflow" >/dev/null ||
      failed=1
    maintenance_airflow_changed=false
  fi
  if "$maintenance_grafana_changed"; then
    remote "sudo -n k3s kubectl -n $ns scale deployment/grafana --replicas=$maintenance_restore_grafana" >/dev/null ||
      failed=1
    maintenance_grafana_changed=false
  fi
  if [[ -n "$maintenance_restore_auto" ]]; then
    patch_argo_auto "$ns" "$maintenance_restore_auto" || failed=1
    maintenance_restore_auto=""
  fi
  if ((failed)); then
    echo "WARNING: Could not fully restore maintenance state; inspect $ns and Argo CD job-market-$ns immediately." >&2
    return 1
  fi
}
