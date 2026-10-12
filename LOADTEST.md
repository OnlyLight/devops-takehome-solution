# Load test: results and what they mean

Run: `./scripts/run-all.sh --full`, or one profile: `docker compose exec -T -e PROFILE=load toolbox bash /scripts/60-loadtest.sh` (profiles: `smoke` ~30 s, `load` ~6 min, `stress` ~12 min). Evidence goes to `loadtest/evidence/<profile>/`.

Setup: k3d (1 server + 4 agents) on one laptop. k6 runs in the toolbox container and goes through the Ingress (Traefik). k6, Prometheus, Grafana and the cluster share one Docker VM. k6 uses an open model (`ramping-arrival-rate`): requests arrive at a fixed rate, so a slow service cannot slow the test down.

## Thresholds

I first measured one pod alone (no HPA, same image and limits, through Traefik, 20 s per fixed arrival rate; `loadtest/baseline.sh`, output in `loadtest/evidence/baseline.txt`). Up to 4 req/s the p95 stays between 160 and 277 ms with 0 errors. At 5 req/s it already collapses (p95 8.9 s, still 0% errors); at 6 and 8 req/s 56% and 82% of the requests fail. The thresholds sit between a healthy run and a collapsed run.

| Threshold | Value | Why |
|---|---|---|
| `http_req_failed` | < 1% | healthy runs: 0 of 4049; baseline at 6 req/s per pod: 56%; `stress`: 77%. At 5 req/s per pod the failures were still 0%, which is why p95 is a threshold too |
| `http_req_duration` p95 | < 500 ms | baseline stable: 160-277 ms; healthy `load` runs: 414-438 ms while scaling out (the margin is only 12-17%); `stress`: 10 s |
| `http_req_duration` p99 | < 1500 ms | healthy `load` runs: 455-517 ms; `stress`: 10 s (the client timeout) |

The smoke profile with `P95_MS=50` fails on purpose, which shows the thresholds can fail: p95 was 241.9 ms against 50 ms, the other two thresholds passed, and the script exited 1 (`loadtest/evidence/threshold-fail.txt`).

## Results

| Run | Load | Errors | p95 | p99 | HPA | Alert | Source |
|---|---|---|---|---|---|---|---|
| `load` #1 | 3 to 8 to 20 req/s, 6 min | 0 / 4049 | 437.9 ms | 516.5 ms | 3 to 4 to 6 to 8 | silent | `evidence/load/first-run-console.txt` |
| `load` #2 | same | 0 / 4049 | 413.8 ms | 455.5 ms | 3 to 4 to 5 to 6 to 8 | silent | `evidence/load/` |
| `stress` | 10 to 50 req/s, 8 min | 77% (timeouts) | 10 s | 10 s | 3 to 8 (max) | pending, then firing | `evidence/stress/` |

In `load` #2 the HPA decided to scale at 16:20:10 (CPU 72% of the request) and had 8 replicas at 16:22:39 (`hpa-timeline.tsv`). At the peak: 5 spot + 3 on-demand, none on the GPU or control-plane node. The extras land on on-demand because the spread constraint (`maxSkew: 2`) forbids too many on spot. Screenshot taken during the first `load` run: `docs/img/grafana-load.png`.

## Capacity and bottleneck

With 8 replicas the service sustained 20 req/s with p95 under 500 ms (the `load` plateau). Under `stress` it collapsed (77% errors) and the HPA was already at `maxReplicas: 8`. The likely bottleneck is the app CPU limit (500m), but I did not measure the node or Traefik here, so that is a hypothesis. I did not investigate why only about 20 of the theoretical 32 req/s (8 pods x 4) were reached, or why throughput fell once overloaded.

## What I would scale first in production

1. The CPU limit: it doubles the latency of a single request (about 200 ms instead of 100 ms).
2. `maxReplicas` (the HPA ran out of headroom) and `minReplicas` for a known peak (the first scale-out came about a minute after the load rose).
3. The work per request. Traefik is a single replica: not the bottleneck here, but a single point of failure.

## Alert threshold

`QuoteApiHighLatency` fires when p95 of `/api/quote` is above 0.5 s for 2 minutes. I chose latency because under saturation the service answers very slowly and the clients time out (77% failures in `stress`), so a 5xx-ratio alert would likely stay silent during the incident. 0.5 s is the same value k6 enforces: above the healthy 414-438 ms, far below the collapse. `for: 2m` ignores the short spike while the HPA scales out. Observed: silent during `load`; during `stress` pending at 16:06:49, firing at 16:08:48, inactive again at 16:14:21 (`evidence/stress/hpa-timeline.tsv`). There is no Alertmanager (cut on purpose), so the alert is visible in Prometheus and nobody is notified. With no traffic the p95 is NaN, so it does not fire at idle.

## Limits

- One machine and one configuration; k6 shares the Docker VM with the cluster.
- Two `load` runs and one `stress` run, not a statistical sample; the raw files of the first `load` run were overwritten, only its console output is kept.
- Prometheus quantiles are interpolated inside buckets, k6 numbers are exact.
- `stress` reported 401 dropped iterations: k6 hit its VU cap, so not all intended load was sent.
