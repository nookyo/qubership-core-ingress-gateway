# Ingress Gateway
## Overview
Ingress gateway is based on [`Envoy proxy`](https://www.envoyproxy.io).
It's documented fully and the documentation can be read [here](https://www.envoyproxy.io/docs/envoy/latest/).

## Custom configuration
The configuration of gateway is loaded dynamically from [Control plane](https://github.com/netcracker/qubership-core-control-plane.git) service side.
There are four gateways in the cloud environment. They are `public`, `private`, `internal` and `egress`.

## Graceful shutdown
Ingress gateway is set up Termination Grace Period to 60 second.
During this period gateway waits:
1. When Kubernetes stop passing traffic through the gateway so that new requests go to next gateway instance if available.
2. Complete of the current active connections. 
In case long run request, requester gets the close connection error. \
And to finish requester has to retry request to reach next available gateway.
Termination Grace Period is configurable through the environment variable GW_TERMINATION_GRACE_PERIOD_S in gateway pod.
 



