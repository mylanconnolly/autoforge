defmodule Autoforge.Cldr do
  use Cldr,
    locales: ["en"],
    default_locale: "en",
    gettext: AutoforgeWeb.Gettext,
    providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime]
end
