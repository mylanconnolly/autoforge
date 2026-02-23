defmodule Autoforge.Markdown do
  @moduledoc """
  Markdown rendering helper using MDEx.
  """

  @doc """
  Renders a markdown string to HTML.

  Returns a `Phoenix.HTML.safe` tuple for use in HEEx templates.
  """
  def to_html(markdown) when is_binary(markdown) do
    {:ok, html} =
      MDEx.to_html(markdown,
        extension: [
          strikethrough: true,
          table: true,
          autolink: true,
          tasklist: true
        ],
        render: [unsafe: true]
      )

    Phoenix.HTML.raw(html)
  end

  def to_html(_), do: Phoenix.HTML.raw("")
end
