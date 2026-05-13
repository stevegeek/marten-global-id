ENV["MARTEN_ENV"] = "test"

require "spec"
require "sqlite3"
require "../src/marten_global_id"
require "marten/spec"

require "./test_project/app"
require "./test_project/models/**"

Marten.configure :test do |config|
  config.secret_key = "__insecure_spec_secret_#{Random::Secure.random_bytes(16).hexstring}__"
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
