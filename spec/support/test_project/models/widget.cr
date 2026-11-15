class Widget < Marten::Model
  include MartenGlobalId::ModelMixin

  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 64
end
