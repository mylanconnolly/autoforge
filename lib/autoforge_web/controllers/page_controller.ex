defmodule AutoforgeWeb.PageController do
  use AutoforgeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
