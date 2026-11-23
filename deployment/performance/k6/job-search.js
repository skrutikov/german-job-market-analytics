import http from "k6/http";
import { check, sleep } from "k6";

// Explicit target avoids accidentally stress-testing a public endpoint.
// Start the local SSH tunnel with ./kubernetes_start.sh dev first.
const BASE_URL = (__ENV.BASE_URL || "").replace(/\/+$/, "");
if (!/^https?:\/\/.+/.test(BASE_URL)) {
  throw new Error("Set BASE_URL explicitly, e.g. -e BASE_URL=http://127.0.0.1:8088");
}

const profile = __ENV.PROFILE || "smoke";
const profiles = {
  smoke: {
    executor: "per-vu-iterations",
    vus: 1,
    iterations: 5,
    maxDuration: "1m",
  },
  ramp: {
    executor: "ramping-vus",
    startVUs: 1,
    stages: [
      { duration: "15s", target: 1 },
      { duration: "20s", target: 5 },
      { duration: "30s", target: 10 },
      { duration: "30s", target: 20 },
      { duration: "15s", target: 0 },
    ],
    gracefulRampDown: "10s",
  },
};
if (!profiles[profile]) {
  throw new Error("Unknown PROFILE; choose smoke or ramp");
}

export const options = {
  scenarios: {
    [profile]: profiles[profile],
  },
  thresholds: {
    // Provisional functional guardrails, NOT measured production SLOs.
    http_req_failed: ["rate<0.05"],
    checks: ["rate>0.95"],
  },
};

const keywords = ["Data Engineer", "Python", "AI Engineer", null];

export default function () {
  const keyword = keywords[Math.floor(Math.random() * keywords.length)];
  const query = keyword
    ? `?keyword=${encodeURIComponent(keyword)}&limit=10`
    : "?limit=10";

  const response = http.get(`${BASE_URL}/api/jobs${query}`, {
    tags: { endpoint: "job_search" },
    timeout: "15s",
  });
  check(response, {
    "HTTP 200": (r) => r.status === 200,
    "JSON array response": (r) => {
      if (r.status !== 200) return false;
      try {
        return Array.isArray(r.json());
      } catch (error) {
        return false;
      }
    },
  });
  sleep(0.75 + Math.random() * 0.5);
}
