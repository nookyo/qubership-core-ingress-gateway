#!/usr/bin/env bash

export GRACE_PERIOD_S=${GW_TERMINATION_GRACE_PERIOD_S:=60}
# This is a local duration of drain before killing envoy process.
# We subtract 10 seconds because stopping of envoy should happen before reaching global GW_TERMINATION_GRACE_PERIOD_S.
# Global GW_TERMINATION_GRACE_PERIOD_S is that period after which Kubernetes forced stops the pod.
let DRAIN_TIME_S=${GRACE_PERIOD_S}-10

export INTERNAL_TLS_ENABLED=${INTERNAL_TLS_ENABLED:=false}
echo "INTERNAL_TLS_ENABLED: '$INTERNAL_TLS_ENABLED'"
config_file='/envoy/config/envoy.yaml'
echo "config_file: '$config_file'"
cp /envoy/envoy.yaml $config_file

# read bytes from cgroup and subtract 10 mb for container docker usage
delta=10485760
if [ -f "/sys/fs/cgroup/memory/memory.memsw.limit_in_bytes" ]; then
  export MAX_HEAP_SIZE_BYTES=$(($(cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes)-delta))
elif [ -f "/sys/fs/cgroup/memory.max" ]; then
  export MAX_HEAP_SIZE_BYTES=$(($(cat /sys/fs/cgroup/memory.max)-delta))
else
  export MAX_HEAP_SIZE_BYTES=$(($(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)-delta))
fi
echo "Max Heap size is set to $MAX_HEAP_SIZE_BYTES bytes"
export TRACING_ENABLED=${TRACING_ENABLED:=false}
export TRACING_HOST=${TRACING_HOST:=nc-diagnostic-agent}
export ZIPKIN_PORT=${ZIPKIN_PORT:=9411}
export XDS_CLUSTER_HOST=${XDS_CLUSTER_HOST:=control-plane}
export XDS_CLUSTER_PORT=${XDS_CLUSTER_PORT:=15010}
export RUN_COREDNS=${RUN_COREDNS:=false}
export LOG_LEVEL=${LOG_LEVEL:=info}

envsubst <${config_file} >${config_file}.tmp && mv ${config_file}.tmp ${config_file}
# See full current list in http://man7.org/linux/man-pages/man7/signal.7.html
# do not trap on 'SIGCHLD' (Child stopped or terminated) we will handle child exit via 'wait -p -n ...' command
export SIGNALS_TO_RETHROW="
SIGHUP
SIGINT
SIGQUIT
SIGILL
SIGABRT
SIGFPE
SIGSEGV
SIGPIPE
SIGALRM
SIGTERM
SIGUSR1
SIGUSR2
SIGCONT
SIGSTOP
SIGTSTP
SIGTTIN
SIGTTOU
SIGBUS
SIGPROF
SIGSYS
SIGTRAP
SIGURG
SIGVTALRM
SIGXCPU
SIGXFSZ
SIGSTKFLT
SIGIO
SIGPWR
SIGWINCH
"

coredns_pid=0
envoy_pid=0

rethrow_handler() {
  local sig_id="$1"
  echo "[`date +"%D %T.%N"`] Got $sig_id sig in entrypoint."
  local drain_time_s="$2"

  if [ "$sig_id" == "SIGTERM" ]; then
    if [ -z $drain_time_s ]; then
      local drain_time_s=15
    fi
    echo "[`date +"%D %T.%N"`] Sleep for drain period $drain_time_s seconds"
    # Waiting until active connections finish its work
    # and DNS is updated so the Service passes the traffic through a new running pod
    # and to prevent 503\502 error on rollout new deployment https://rtfm.co.ua/en/kubernetes-nginx-php-fpm-graceful-shutdown-and-502-errors/
    ./bin/sleep $drain_time_s
  fi

  try_killing_process "envoy" "$envoy_pid" "$sig_id"
  try_killing_process "coredns" "$coredns_pid" "$sig_id"
  exit -1
}

try_killing_process() {
  local proc_name="$1"
  local proc_id="$2"
  local sig_id="$3"
  if [ $proc_id -ne 0 ]; then
    echo "Signaling '$sig_id' to '$proc_name' process"
    kill -"$sig_id" "$proc_id"
    wait "$proc_id"
    local ret_code=$?
    echo "'$proc_name' process' exit code = $ret_code"
  fi
}

echo "trap on signals ..."
for sig in $SIGNALS_TO_RETHROW; do trap "rethrow_handler $sig $DRAIN_TIME_S" $sig  2>&1 >/dev/null; done

if [ $RUN_COREDNS == "true" ]; then
  echo "run 'coredns' in background"
  ./usr/bin/coredns -conf /CoreDNSFile &
  coredns_pid="$!"
  echo "coredns_pid = $coredns_pid"
fi

echo "define envoy concurrency"
envoy_concurrency=""
if [[ $ENVOY_CONCURRENCY -ne 0 ]]; then
envoy_concurrency="--concurrency ${ENVOY_CONCURRENCY}"
fi
echo "envoy_concurrency=${envoy_concurrency}"

echo "run 'envoy' in background"
envoy  $envoy_concurrency --service-cluster ${SERVICE_NAME_VARIABLE} --service-node ${POD_HOSTNAME} --drain-time-s 45 --parent-shutdown-time-s 60 -c ${config_file} --log-level ${LOG_LEVEL} --log-format "[%Y-%m-%dT%T.%e] [%l] [request_id=-] [tenant_id=-] [thread=%t] [class=-] [%n] [%g:%#] %v" &
envoy_pid="$!"
echo "envoy_pid = $envoy_pid"

if [ $RUN_COREDNS == "true" ]; then
  wait -n "$envoy_pid" "$coredns_pid" # wait for the first terminated process of these two
  exit_code="$?"
  echo "'envoy' or 'coredns' process exited with code = $exit_code"

  echo "Trying to kill 'coredns' process before exit"
  try_killing_process "coredns" "$coredns_pid" "SIGKILL"
  echo "Trying to kill 'envoy' process before exit"
  try_killing_process "envoy" "$envoy_pid" "SIGKILL"
else
  wait -n "$envoy_pid"
  exit_code="$?"
  echo "'envoy' process exited with code = $exit_code"
fi

exit $exit_code
