# grafana, w/ patches
#
# Since 2026-11-03, GitHub 403s git smart-HTTP requests w/ nanogit's default
# `User-Agent: nanogit/0`, which breaks Git Sync (`github` repos turn
# unhealthy w/ "not authorized"). Remove the patch once upstream sets its own
# User-Agent.
{ grafana }:
grafana.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./nanogit-user-agent.patch ];
})
