const client = require("prom-client");

// Default registry collects process/Node.js metrics (CPU, memory, event loop).
const register = new client.Registry();
register.setDefaultLabels({ app: "conduit-backend" });
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// Express middleware: times each request and records it once the response ends.
function metricsMiddleware(req, res, next) {
  if (req.path === "/metrics") return next();

  const end = httpRequestDuration.startTimer();
  res.on("finish", () => {
    const route = req.route?.path ? req.baseUrl + req.route.path : req.path;
    const labels = {
      method: req.method,
      route,
      status_code: res.statusCode,
    };
    end(labels);
    httpRequestsTotal.inc(labels);
  });

  next();
}

// Handler for GET /metrics — Prometheus scrape target.
async function metricsHandler(req, res) {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
}

module.exports = { register, metricsMiddleware, metricsHandler };
