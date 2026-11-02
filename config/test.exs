import Config

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
    AshUi.Expressions.Default,
    AshUi.Expressions.TestTextLength
  ]
