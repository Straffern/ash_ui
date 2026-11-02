import Config

# Preserve validation behavior from Ash 3.33 during the 3.36 cutover.
config :ash, default_string_length_count: :mixed

# CustomExpressions do not inherit from path deps: every consuming app
# registers AshUi's expression modules itself (SYNTHESIS App. A).
config :ash,
  custom_expressions: [
    AshUi.Expressions.ToString,
    AshUi.Expressions.Humanize,
    AshUi.Expressions.RelativeTime,
    AshUi.Expressions.TimeAgoInWords,
    AshUi.Expressions.Truncate,
    AshUi.Expressions.StripPrefix,
    AshUi.Expressions.ClassJoin,
    AshUi.Expressions.Blank,
    AshUi.Expressions.Present,
    AshUi.Expressions.Empty,
    AshUi.Expressions.NilifBlank,
    AshUi.Expressions.Join,
    AshUi.Expressions.Count,
    AshUi.Expressions.SortBy,
    AshUi.Expressions.AppendUnique,
    AshUi.Expressions.FindBy,
    AshUi.Expressions.FieldErrors,
    AshUi.Expressions.Default
  ]

if config_env() == :test do
  # Ash's ETS data layer logs every operation at debug level — pure noise in
  # bench output and a real cost at 10k-row seeds
  config :logger, level: :warning
end
