module MartenGlobalId
  # Settings namespace for marten-global-id. Hooks into Marten's standard
  # settings DSL so the host app can register participating classes
  # alongside any other Marten configuration:
  #
  # ```
  # Marten.configure do |config|
  #   config.global_id.allowed_classes = [
  #     MyApp::Book,
  #     MyApp::Markdown,
  #     MyApp::Leafables::Page,
  #   ]
  # end
  # ```
  #
  # The allowlist gates which classes the locator will instantiate.
  # Tokens referencing any class not in this list are rejected the same
  # way an invalid signature is — they return nil from
  # `MartenGlobalId.locate`. This keeps the shard host-class-agnostic
  # (Crystal can't resolve a class name to a class at runtime, so the
  # set has to be enumerated somewhere — better in the host app than
  # baked into the shard).
  class Configuration < Marten::Conf::Settings
    namespace :global_id

    # The allowlist of model classes that participate in signed global
    # ids. Defaults to empty — the host app must populate this before
    # `MartenGlobalId.locate` will resolve anything.
    property allowed_classes : Array(Marten::DB::Model.class) = [] of Marten::DB::Model.class
  end
end
