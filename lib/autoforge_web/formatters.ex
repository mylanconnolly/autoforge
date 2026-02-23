defmodule AutoforgeWeb.Formatters do
  @moduledoc """
  CLDR-backed formatting helpers available in all views and components.
  """

  @doc """
  Formats a date using CLDR's `:medium` format (e.g. "Feb 23, 2026").
  """
  def format_date(datetime) do
    Autoforge.Cldr.Date.to_string!(datetime, format: :medium)
  end

  @doc """
  Formats a time using CLDR's `:short` format (e.g. "2:30 PM").
  """
  def format_time(datetime) do
    Autoforge.Cldr.Time.to_string!(datetime, format: :short)
  end

  @doc """
  Formats a datetime using CLDR's `:medium` format.
  """
  def format_datetime(datetime) do
    Autoforge.Cldr.DateTime.to_string!(datetime, format: :medium)
  end

  @doc """
  Formats a number using CLDR (e.g. 1234 → "1,234").
  """
  def format_number(number) do
    Autoforge.Cldr.Number.to_string!(number)
  end

  @doc """
  Formats a number as a percentage (e.g. 0.75 → "75%").
  """
  def format_percent(number) do
    Autoforge.Cldr.Number.to_string!(number, format: :percent)
  end
end
