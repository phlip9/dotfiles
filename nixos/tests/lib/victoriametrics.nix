# NixOS module for tests that query VictoriaMetrics. Removes two delays
# between a scrape and the first query that sees it: the query latency
# offset and cached empty series matches. Rows VM hasn't flushed yet are
# still invisible (its ~2s flush, or `/internal/force_flush`).
#
# Import it into the node that runs VictoriaMetrics, ex: w/ phlip9-o11y.
{
  services.victoriametrics.extraOptions = [
    # Queries hide samples younger than `-search.latencyOffset` (30s), which
    # would delay every "is it scraped yet" check by 30s.
    "-search.latencyOffset=0s"
    # A query that runs before its series exists caches the empty match
    # until the next indexdb flush callback, up to 10s later. A 1-byte
    # cache evicts every entry right away.
    "-storage.cacheSizeIndexDBTagFilters=1"
    # One error per scrape of a target that is still starting up.
    # `/api/v1/targets` keeps the last error per target.
    "-promscrape.suppressScrapeErrors"
  ];
}
