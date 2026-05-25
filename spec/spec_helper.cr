ENV["MARTEN_ENV"] = "test"

require "spec"
require "sqlite3"
require "../src/marten_global_id"
require "marten/spec"

require "./test_project/app"
require "./test_project/models/**"

# Fixed spec secret — debuggability over per-run rotation. A failing
# spec's token can be re-signed by hand from the literal key, which is
# the cheapest way to triage a HMAC mismatch. Matches sister shard
# `marten-signed-id`'s `SPEC_SECRET_KEY` for cross-shard consistency.
# The `before_each` below only resets the allowlist, not the secret;
# if a future spec wants to verify behaviour under a *rotated* secret
# it'll need to stash + restore `Marten.settings.secret_key` itself.
SPEC_SECRET_KEY = "__insecure_spec_secret_DO_NOT_USE__"

Marten.configure :test do |config|
  config.secret_key = SPEC_SECRET_KEY
  config.log_level = ::Log::Severity::None

  config.installed_apps = [MartenGlobalIdSpecApp]

  config.database do |db|
    db.backend = :sqlite
    db.name = ":memory:"
  end
end

# Reset the allowlist between specs so a test that didn't register
# `Widget` (e.g. the "class not in allowlist" spec) doesn't pick up
# leaked state from a neighbour. The settings object is a singleton on
# `Marten.settings`, so we mutate in place.
Spec.before_each do
  Marten.settings.global_id.allowed_classes = [] of ::Marten::DB::Model.class
end
