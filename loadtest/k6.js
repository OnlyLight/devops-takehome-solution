// k6 load test for quote-api, through the Ingress (Traefik), not directly at the pods.
//
//   PROFILE=smoke   30 s at 2 req/s: a quick check, and the way to prove the thresholds can fail (P95_MS=50)
//   PROFILE=load    default: ramp 3 -> 8 -> 20 req/s so the HPA has to scale out; thresholds enforced
//   PROFILE=stress  keep ramping to 50 req/s to find where the service collapses; exploratory, no thresholds
//
// The model is an open one (ramping-arrival-rate): requests arrive at a fixed rate whatever the latency, so a
// slow service cannot slow the test down (a closed model with a fixed number of users would hide saturation).
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://k3d-itv-serverlb';
const PROFILE = __ENV.PROFILE || 'load';

// Thresholds come from the measured single-pod baseline (see LOADTEST.md); every one can be overridden.
//
// Baseline (loadtest/baseline.sh, output in loadtest/evidence/baseline.txt; 500m CPU limit, one pod, through
// Traefik): up to 4 req/s per pod the p95 is 160-277 ms with 0 errors; at 5 req/s it collapsed (p95 8.9 s, with 0%
// errors in that run); at 6 req/s 56% of the requests failed.
//  - FAIL_RATE 1%: healthy runs have 0 errors; saturation gave 56% (baseline, 6 req/s) and 77% (stress). At the
//    5 req/s edge the failures were still 0%, which is why the p95 threshold exists too.
//  - P95_MS 500: roughly 2x the stable baseline p95. It leaves room for the seconds an arrival-rate step spends above
//    one pod's capacity before the HPA's new replicas are Ready (healthy load runs: 414-438 ms), and is far below
//    the ~9-10 s seen at collapse.
//  - P99_MS 1500: the tail may be worse than p95 during a scale-out step (healthy load runs: 455-517 ms), but must
//    stay far below the 10 s timeouts seen at collapse.
const P95_MS = Number(__ENV.P95_MS || 500);
const P99_MS = Number(__ENV.P99_MS || 1500);
const FAIL_RATE = Number(__ENV.FAIL_RATE || 0.01);

const profiles = {
  smoke: [
    { duration: '10s', target: 2 },
    { duration: '20s', target: 2 },
  ],
  load: [
    { duration: '30s', target: 3 }, //  below the HPA trigger (3 pods x ~1.8 req/s): the quiet baseline
    { duration: '60s', target: 8 }, //  above it: the HPA must scale out
    { duration: '90s', target: 8 }, //  plateau while replicas come up
    { duration: '60s', target: 20 }, // ramp again (still under the ~32 req/s of 8 pods)
    { duration: '90s', target: 20 }, // plateau
    { duration: '30s', target: 0 },
  ],
  stress: [
    { duration: '60s', target: 10 },
    { duration: '60s', target: 20 },
    { duration: '60s', target: 30 },
    { duration: '60s', target: 40 },
    { duration: '60s', target: 50 },
    // Hold well past capacity (8 pods ~ 32 req/s): the latency alert needs p95 > 0.5 s for 2 minutes over a 2-minute window.
    { duration: '180s', target: 50 },
  ],
};
if (!profiles[PROFILE]) {
  throw new Error(`unknown PROFILE '${PROFILE}' (smoke | load | stress)`);
}

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 800, // enough VUs that the generator itself is not the bottleneck at 50 req/s x seconds of latency
      stages: profiles[PROFILE],
    },
  },
  // The stress profile is meant to break the service, so it only reports.
  thresholds:
    PROFILE === 'stress'
      ? {}
      : {
          http_req_failed: [`rate<${FAIL_RATE}`],
          http_req_duration: [`p(95)<${P95_MS}`, `p(99)<${P99_MS}`],
        },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.get(`${BASE_URL}/api/quote`, { timeout: '10s' });
  check(res, {
    'status is 200': (r) => r.status === 200,
    'body has a quote': (r) => typeof r.body === 'string' && r.body.includes('"quote"'),
  });
}
