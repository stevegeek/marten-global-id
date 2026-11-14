# Second class for testing the allowlist multi-class path + namespaced
# class-name handling (the writebook port resolves
# `Books::Leafables::Page`, so we want at least one model whose name
# round-trips through the `class.name` lookup).
module Gadgets
  class Page < Marten::Model
    include MartenGlobalId::ModelMixin

    field :id, :big_int, primary_key: true, auto: true
    field :title, :string, max_size: 64
  end
end
