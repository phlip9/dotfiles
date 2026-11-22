# Tune vmagent and VictoriaMetrics for tests that poll for new samples.
#
#   vmagent -> remote write -> VictoriaMetrics -> test query
#
# Import on each node running either service. VictoriaMetrics queries see
# samples after a storage flush. Use `/internal/force_flush` to trigger one.
{
  services.victoriametrics.extraOptions = [
    # Include fresh samples in queries. The default offset hides the last 30s.
    "-search.latencyOffset=0s"

    # A 1-byte cache evicts empty matches immediately, so a query issued
    # before its series exists can see it as soon as the index is flushed.
    "-storage.cacheSizeIndexDBTagFilters=1"
  ];

  services.vmagent.extraArgs = [
    # Make pending writes eligible at the next 1s flush check.
    "-remoteWrite.flushInterval=100ms"

    # Suppress per-scrape error logs. `/targets` shows each target's last error.
    "-promscrape.suppressScrapeErrors"
  ];
}
