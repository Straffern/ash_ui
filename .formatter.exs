# Used by "mix format"
locals_without_parens = [
  default: 1,
  location: 1,
  param: 1,
  param: 2,
  param: 3,
  query: 1,
  query: 2,
  query: 3,
  route: 1,
  route: 2,
  state: 1,
  strict_expressions?: 1,
  stylesheets: 1,
  type: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
