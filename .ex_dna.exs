%{
  min_mass: 25,
  ignore: ["test/**", "deps/**"],
  excluded_macros: [:@, :schema, :pipe_through, :plug],
  normalize_pipes: true,
  literal_mode: :abstract,
  min_similarity: 0.85
}
