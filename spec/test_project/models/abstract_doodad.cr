# Abstract model used by the "abstract class in allowlist" spec (M2).
# An abstract Marten model raises if you call `klass.get(pk: ...)` on
# it — the locator must defend against that path and return nil rather
# than blowing up the documented "always returns nil on failure"
# contract.
abstract class AbstractDoodad < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
end
