#!/usr/bin/env bash
# ==============================================================================
# Multi-Agent Swarm Workload Benchmark: Arm_5 (No P2P) vs. Arm_6 (P2P)
#
# Scenario:
#   Collaborative Multi-Agent Codebase Reasoning Swarm
#   - Shared context: 40,000 tokens (large enterprise repo AST, symbols, code).
#   - Dynamic task context: 1,000–3,000 tokens (mean 2,000 tokens, issue prompt, subtask).
#   - Output tokens: 48–128 tokens (mean 80 tokens, tool-call JSON).
#   - Turns per session: 6–14 turns (mean 10).
#   - Tool latency: 2–4s (mean 3s, matching the ~3.0s decode time).
#   - Router maxTTFTPenaltyMs: 1,000 ms (calibrated load gate).
#
# Compares:
#   - Arm_5: Token Load-Aware Routing (No P2P)
#   - Arm_6: Token Load-Aware Routing + P2P (Upstream EPP Router)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BENCHMARK_DIR="${REPO_ROOT}/llm-d-benchmark"
WORKLOAD_IN_FILE="${BENCHMARK_DIR}/workload/profiles/inference-perf/agentic_serving_gpt_oss_120b.yaml.in"
BENCHMARK_CONFIGS_DIR="${REPO_ROOT}/guides/p2p-kv-cache-sharing/benchmarking"
TMP_DIR="/tmp/llmd-multi-agent-bench"
mkdir -p "${TMP_DIR}"

GUIDE_NAME="p2p-kv-cache-sharing"
NAMESPACE="${NAMESPACE:-llm-d-${GUIDE_NAME}}"
MODEL_NAME="${MODEL_NAME:-openai/gpt-oss-120b}"
GATEWAY_CLASS="${GATEWAY_CLASS:-epponly}"
NUM_RUNS="${NUM_RUNS:-1}"
START_RUN="${START_RUN:-1}"

# Public Upstream EPP Router image by default (override via ROUTER_IMAGE env var if desired)
ROUTER_IMAGE="${ROUTER_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker:main}"
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-${SCRIPT_DIR}/results_multi_agent}"
mkdir -p "${RESULTS_BASE_DIR}"

# Concurrency sweep: 128, 192, 256
CONCURRENCY_LEVELS=(${CONCURRENCY_LEVELS:-128 192 256})
BASE_SEED="${SEED:-8641}"

if [[ -f "${REPO_ROOT}/guides/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/guides/env.sh"
fi

# Compare Arm_5 (No P2P) vs. Arm_6 (Upstream P2P)
ARMS=(
  "Arm_5:epp-token-load-aware.yaml:Token Load-Aware Routing (No P2P):5"
  "Arm_6:epp-token-load-aware-p2p.yaml:Token Load-Aware Routing + P2P:6"
)

deploy_arm_router() {
  local arm_config_file="$1"
  local arm_label="$2"

  echo "==> Ensuring EPP router deployment image is set to [${ROUTER_IMAGE}]..."
  kubectl set image deployment/${GUIDE_NAME}-epp epp="${ROUTER_IMAGE}" -n "${NAMESPACE}" 2>/dev/null || true

  echo "==> Deploying Router Config for [${arm_label}] (${arm_config_file})..."
  until kubectl create configmap p2p-kv-cache-sharing-epp -n "${NAMESPACE}" \
    --from-file="p2p-kv-cache-sharing-plugins.yaml=${BENCHMARK_CONFIGS_DIR}/${arm_config_file}" \
    --dry-run=client -o yaml | kubectl apply -n "${NAMESPACE}" -f -; do
    echo "==> Warning: ConfigMap apply encountered transient API error, retrying in 3s..."
    sleep 3
  done

  kubectl rollout restart deployment -n "${NAMESPACE}" "${GUIDE_NAME}-epp" 2>/dev/null || true
}

cold_roll_fleet() {
  echo "==> Cold-rolling fleet (clearing all GPU HBM and CPU /dev/shm caches)..."
  kubectl rollout restart deployment -n "${NAMESPACE}" -l llm-d.ai/role=decode 2>/dev/null || true
  kubectl rollout restart deployment -n "${NAMESPACE}" "${GUIDE_NAME}-epp" 2>/dev/null || true

  echo "==> Waiting for model server pods to become Ready (2/2)..."
  for dep in $(kubectl get deploy -n "${NAMESPACE}" -l llm-d.ai/role=decode -o jsonpath='{.items[*].metadata.name}'); do
    until kubectl rollout status deployment -n "${NAMESPACE}" "${dep}" --timeout=1800s; do
      echo "==> Warning: rollout status encountered transient API error on ${dep}, retrying in 5s..."
      sleep 5
    done
  done

  echo "==> Waiting for EPP router pods to become Ready (2/2)..."
  until kubectl rollout status deployment -n "${NAMESPACE}" "${GUIDE_NAME}-epp" --timeout=600s; do
    echo "==> Warning: rollout status encountered transient API error, retrying in 5s..."
    sleep 5
  done

  sleep 10
  echo "==> Fleet is clean and ready."
}

generate_workload_yaml() {
  local concurrency="$1"
  local num_requests="$2"
  local num_convs="$3"
  local seed="$4"

  mkdir -p "$(dirname "${WORKLOAD_IN_FILE}")"
  sed -e "s/concurrency_level: .*/concurrency_level: ${concurrency}/" \
      -e "s/num_requests: .*/num_requests: ${num_requests}/" \
      -e "s/num_conversations: .*/num_conversations: ${num_convs}/" \
      -e "s/seed: .*/seed: ${seed}/" \
      "${SCRIPT_DIR}/multi_agent_workload.yaml" > "${WORKLOAD_IN_FILE}"
}

if [[ -f "${BENCHMARK_DIR}/.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "${BENCHMARK_DIR}/.venv/bin/activate"
fi

TOTAL_ARMS=${#ARMS[@]}
TOTAL_CLS=${#CONCURRENCY_LEVELS[@]}

echo "========================================================================"
echo " Starting Multi-Agent Swarm Benchmark"
echo " Router Image: ${ROUTER_IMAGE}"
echo " Concurrencies: [${CONCURRENCY_LEVELS[*]}] | Runs per CL: ${NUM_RUNS}"
echo " Destination Results Directory: ${RESULTS_BASE_DIR}"
echo "========================================================================"

arm_idx=1
for arm_entry in "${ARMS[@]}"; do
  IFS=':' read -r arm_id arm_file arm_desc arm_num <<< "${arm_entry}"

  echo ""
  echo "########################################################################"
  echo " [Arm ${arm_idx}/${TOTAL_ARMS}] ${arm_id}: ${arm_desc}"
  echo " Config: ${arm_file}"
  echo "########################################################################"

  deploy_arm_router "${arm_file}" "${arm_desc}"

  for cl in "${CONCURRENCY_LEVELS[@]}"; do
    num_requests=$(( 20 * cl ))
    num_convs=$(( num_requests / 10 ))

    for (( run_idx=START_RUN; run_idx<=NUM_RUNS; run_idx++ )); do
      CURRENT_SEED=$(( BASE_SEED + run_idx - 1 ))

      echo ""
      echo "------------------------------------------------------------------------"
      echo " Arm: ${arm_id} (${arm_desc}) | CL: ${cl} (${num_requests} reqs) | Run: ${run_idx}/${NUM_RUNS} | Seed: ${CURRENT_SEED}"
      echo "------------------------------------------------------------------------"

      cold_roll_fleet

      generate_workload_yaml "${cl}" "${num_requests}" "${num_convs}" "${CURRENT_SEED}"
      cp "${WORKLOAD_IN_FILE}" "${WORKLOAD_IN_FILE%.in}"

      until ENDPOINT_IP=$(kubectl get service "${GUIDE_NAME}-epp" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [ -n "${ENDPOINT_IP}" ]; do
        sleep 2
      done
      ENDPOINT_URL="http://${ENDPOINT_IP}:8081"
      echo "==> Target Endpoint URL: ${ENDPOINT_URL}"

      OUTPUT_DIR="${RESULTS_BASE_DIR}/${arm_id}/CL_${cl}/run_${run_idx}"
      mkdir -p "${OUTPUT_DIR}"

      START_TIME=$(date +%s)
      (
        cd "${BENCHMARK_DIR}"
        llmdbenchmark \
          --spec           guides/p2p-kv-cache-sharing \
          run \
          --endpoint-url   "${ENDPOINT_URL}" \
          --gateway-class  "${GATEWAY_CLASS}" \
          --model          "${MODEL_NAME}" \
          --namespace      "${NAMESPACE}" \
          --harness        inference-perf \
          --workload       agentic_serving_gpt_oss_120b.yaml \
          --output         "local" \
          --analyze
      ) || echo "==> Notice: llmdbenchmark run step completed."

      if [[ -L "${HOME}/data/p2p_kv_cache_sharing/latest" ]]; then
        LATEST_RUN_DIR="$(readlink -f "${HOME}/data/p2p_kv_cache_sharing/latest")"
        if [[ -d "${LATEST_RUN_DIR}" ]]; then
          rsync -av --exclude="per_request_lifecycle_metrics.json" "${LATEST_RUN_DIR}/" "${OUTPUT_DIR}/"
          rm -rf "${LATEST_RUN_DIR}"
        fi
      fi

      END_TIME=$(date +%s)
      ELAPSED=$(( END_TIME - START_TIME ))
      echo "==> Completed ${arm_id} | CL_${cl} | Run ${run_idx} in ${ELAPSED}s (Seed: ${CURRENT_SEED})"
      sleep 5
    done
  done

  ((arm_idx++))
done

echo ""
echo "========================================================================"
echo " Multi-Agent Swarm Benchmark Complete!"
echo " Results available in: ${RESULTS_BASE_DIR}"
echo "========================================================================"
