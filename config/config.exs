import Config

# The test suite's string-length assertions use Ash's mixed counting.
config :ash, default_string_length_count: :mixed

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

env_config = Path.expand("#{config_env()}.exs", __DIR__)

if File.exists?(env_config) do
  import_config "#{config_env()}.exs"
end
