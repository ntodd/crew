import Config

# crew_cache's variables (§21.3), set by crew-cache.service from
# ${CREW_DATA_DIR}/cache/env; see CrewCache.Env. Only these: the
# test-only settings (address policy exceptions, fake upstreams) are
# never read from the environment.
if config_env() == :prod do
  config :crew_cache, CrewCache.Env.config(System.get_env())
end
