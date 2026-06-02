import Config

# Read from env vars in every env so the same image can be aimed at a local
# dev server or a remote stress-test target without recompiling. Compile-time
# defaults (config/dev.exs etc.) apply when the var is unset.
if http = System.get_env("RC_BOT_TARGET_HTTP") do
  config :rc_bot, target_http: http
end

if ws = System.get_env("RC_BOT_TARGET_WS") do
  config :rc_bot, target_ws: ws
end

if System.get_env("RC_BOT_AUTOSTART") == "true" do
  config :rc_bot, autostart_fleet: true
end
